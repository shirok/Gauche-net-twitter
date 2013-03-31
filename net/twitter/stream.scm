(define-module net.twitter.stream
  (use net.oauth)
  (use net.twitter.core)
  (use rfc.http)
  (use rfc.json)
  (use rfc.uri)
  (use srfi-13)
  (use text.parse)
  (export
   user-stream
   sample-stream
   filter-stream
   firehose-stream
   site-stream
   ))
(select-module net.twitter.stream)

;;;
;;; Stream API
;;;

;; https://dev.twitter.com/docs/streaming-apis
;; https://dev.twitter.com/docs/streaming-apis/streams/public

;; TODO http://practical-scheme.net/chaton/gauche/a/2011/02/11
;; PROC accept one arg contains parsed json object
(define (user-stream cred proc :key (replies #f) (delimited #f)
                     (stall-warnings #f) (with #f) (track #f)
                     (locations #f)
                     (raise-error? #f) (error-handler #f)
                     :allow-other-keys _keys)
  (set! track (stringify-param track))
  (open-stream cred proc 'post "https://userstream.twitter.com/1.1/user.json"
               (api-params _keys replies delimited stall-warnings
                           with track locations)
               :error-handler (or error-handler raise-error?)))

(define (sample-stream cred proc :key (delimited #f) (stall-warnings #f)
                       (raise-error? #f) (error-handler #f)
                       :allow-other-keys _keys)
  (open-stream cred proc 'get "https://stream.twitter.com/1.1/statuses/sample.json"
               (api-params _keys delimited stall-warnings)
               :error-handler (or error-handler raise-error?)))

(define (filter-stream cred proc :key (follow #f) (track #f)
                       (locations #f) (delimited #f) (stall-warnings #f)
                       (raise-error? #f) (error-handler #f)
                       :allow-other-keys _keys)
  (set! track (stringify-param track))
  (set! follow (stringify-param follow))
  (open-stream cred proc 'post "https://stream.twitter.com/1.1/statuses/filter.json"
               (api-params _keys delimited follow locations track stall-warnings)
               :error-handler (or error-handler raise-error?)))

;;TODO not yet checked
(define (firehose-stream cred proc :key (count #f) (delimited #f)
                         (stall-warnings #f)
                         (raise-error? #f) (error-handler #f)
                         :allow-other-keys _keys)
  (open-stream cred proc 'get "https://stream.twitter.com/1.1/statuses/firehose.json"
               (api-params _keys count delimited stall-warnings)
               :error-handler (or error-handler raise-error?)))

;;TODO not yet checked
(define (site-stream cred proc :key (follow #f) (delimited #f) (stall-warnings #f)
                     (with #f) (replies #f) (raise-error? #f) (error-handler #f)
                     :allow-other-keys _keys)
  (set! follow (stringify-param follow))
  (open-stream cred proc 'get "https://sitestream.twitter.com/1.1/site.json"
               (api-params _keys follow delimited stall-warnings
                           with replies)
               :error-handler (or error-handler raise-error?)))

(define (open-stream cred proc method url params
                     :key (error-handler #f))

  (define (auth-header)
    (ecase method
      ['get
       (oauth-auth-header "GET" url params cred)]
      ['post
       (oauth-auth-header "POST" url params cred)]))

  (define (stream-looper code headers total retrieve)
    (check-stream-error code headers)
    (let loop ()
      (receive (port size) (retrieve)
        (cond
         [(negative? size)]
         [else
          (and-let* ([s (read-string size port)]
                     [json (safe-parse-json s)])
            (proc json))
          (loop)]))))

  (define (connect)
    (let1 auth (auth-header)
      (receive (scheme host path)
          (parse-uri url)
        (ecase method
          ['get
           (http-get host (if (pair? params)
                            #`",|path|?,(oauth-compose-query params)"
                            path)
                     :secure (string=? "https" scheme)
                     :receiver stream-looper
                     :Authorization auth)]
          ['post
           (http-post host (if (pair? params)
                             #`",|path|?,(oauth-compose-query params)"
                             path)
                      ""
                      :secure (string=? "https" scheme)
                      :receiver stream-looper
                      :Authorization auth)]))))

  (define tcpip-waitsec #f)
  (define too-often-waitsec #f)
  (define http-waitsec #f)

  (define (check-stream-error status headers)
    (cond
     [(equal? status "200")
      (reset-wait-seconds)]
     [else
      (error <twitter-api-error>
             :status status :headers headers
             (format "Failed to open stream with code ~a"
                     status))]))

  (define (reset-wait-seconds)
    (set! tcpip-waitsec 0)
    (set! too-often-waitsec 60)
    (set! http-waitsec 5))

  ;;TODO connection-adapter?
  (define (continue-connect)
    (reset-wait-seconds)
    (while #t
      (guard (e
              [(eq? error-handler #t)
               (raise e)]
              [(<twitter-api-error> e)
               (when error-handler
                 (error-handler e))
               (cond
                [(equal? "420" (condition-ref e 'status))
                 ;; Login too often
                 (sys-sleep too-often-waitsec)
                 (set! too-often-waitsec
                       (* too-often-waitsec 2))]
                [(#/^4/ (condition-ref e 'status))
                 ;; eternal error
                 (raise e)]
                [else
                 (sys-sleep http-waitsec)
                 (set! http-waitsec
                       (min (* http-waitsec 2) 320))])]
              [else
               (when error-handler
                 (error-handler e))
               (set! tcpip-waitsec (min (+ tcpip-waitsec 0.25) 16))
               (sys-nanosleep (* tcpip-waitsec 1000000))])
        (connect))))

  (continue-connect))

(define (safe-parse-json string)
  ;; heading white space cause rfc.json parse error.
  (let1 trimmed (string-trim string)
    (and (> (string-length trimmed) 0)
         (parse-json-string trimmed))))

(define (parse-uri uri)
  (receive (scheme spec) (uri-scheme&specific uri)
    (receive (host path . rest) (uri-decompose-hierarchical spec)
      (values scheme host path))))

