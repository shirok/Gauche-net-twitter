(define-module net.twitter.core
  (use srfi-1)
  (use gauche.parameter)
  (use net.oauth)
  (use rfc.822)
  (use rfc.http)
  (use rfc.json)
  (use rfc.mime)
  (use sxml.ssax)
  (use sxml.sxpath)
  (use util.list)
  (use util.match)
  (use text.tr)
  (export
   <twitter-cred> <twitter-api-error>
   api-params
   build-url
   retrieve-stream check-api-error
   call/oauth->sxml call/oauth
   call/oauth-post->sxml call/oauth-upload->sxml
   ))
(select-module net.twitter.core)

(define twitter-use-https
  (make-parameter #t))

;;
;; Credential
;;

(define-class <twitter-cred> (<oauth-cred>)
  ())

;;
;; Condition for error response
;;

(define-condition-type <twitter-api-error> <error> #f
  (status #f)
  (headers #f)
  (body #f)
  (body-sxml #f)
  (body-json #f))

;;
;; A convenience macro to construct query parameters, skipping
;; if #f is given to the variable.
;; keys are keyword list that append to vars after parsing.
(define-macro (api-params keys . vars)
  `(with-module net.twitter.core
     (append
      (query-params ,@vars)
      (let loop ([ks ,keys]
                 [res '()])
        (cond
         [(null? ks) (reverse! res)]
         [else
          (let* ([key (car ks)]
                 [name (->param-key key)]
                 [v (cadr ks)]
                 [val (->param-value v)])
            (cond
             [(not val)
              (loop (cddr ks) res)]
             [else
              (loop (cddr ks) (cons (list name val) res))]))])))))

(define (->param-key x)
  (string-tr (x->string x) "-" "_"))

(define (->param-value x)
  (cond
   [(eq? x #f) #f]
   [(eq? x #t) "t"]
   [else (x->string x)]))

(define-macro (query-params . vars)
  `(with-module net.twitter.core
     (cond-list
      ,@(map (lambda (v)
               `(,v `(,',(->param-key v)
                      ,(->param-value ,v))))
             vars))))

(with-module rfc.mime
  (define (twitter-mime-compose parts
                                :optional (port (current-output-port))
                                :key (boundary (mime-make-boundary)))
    (for-each (cut display <> port) `("--" ,boundary "\r\n"))
    (dolist [p parts]
      (mime-generate-one-part (canonical-part p) port)
      (for-each (cut display <> port) `("\r\n--" ,boundary "--\r\n")))
    boundary))

(define (parse-xml-string str)
  (call-with-input-string str
    (cut ssax:xml->sxml <> '())))

;;TODO make obsolete
(define (call/oauth->sxml cred method path params . opts)
  (apply call/oauth cred method path params opts))

(define (call/oauth cred method path params . opts)
  (define (call)
    (let1 auth (and cred
                    (oauth-auth-header
                     (if (eq? method 'get) "GET" "POST")
                     (build-url "api.twitter.com" path) params cred))
      (case method
        [(get) (apply http-get "api.twitter.com"
                      #`",|path|?,(oauth-compose-query params)"
                      :Authorization auth :secure (twitter-use-https) opts)]
        [(post) (apply http-post "api.twitter.com" path
                       (oauth-compose-query params)
                       :Authorization auth :secure (twitter-use-https) opts)])))

  (define (retrieve status headers body)
    (%api-adapter status headers body))

  (call-with-values call retrieve))

(define (call/oauth-post->sxml cred path files params . opts)
  (apply
   (call/oauth-file-sender "api.twitter.com")
   cred path files params opts))

(define (call/oauth-upload->sxml cred path files params . opts)
  (apply
   (call/oauth-file-sender "upload.twitter.com")
   cred path files params opts))

(define-macro (hack-mime-composing . expr)
  (let ((original (gensym)))
    `(let ((,original #f))
       (with-module rfc.mime
         (set! ,original mime-compose-message)
         (set! mime-compose-message twitter-mime-compose))
       (unwind-protect
        (begin ,@expr)
        (with-module rfc.mime
          (set! mime-compose-message ,original))))))

(define (call/oauth-file-sender host)
  (^ [cred path files params . opts]
    (define (call)
      (let1 auth (oauth-auth-header
                  "POST" (build-url host path) params cred)
        (hack-mime-composing
         (apply http-post host
                (if (pair? params) #`",|path|?,(oauth-compose-query params)" path)
                files :Authorization auth :secure (twitter-use-https) opts))))

    (define (retrieve status headers body)
      (%api-adapter status headers body))

    (call-with-values call retrieve)))

(define (build-url host path)
  (string-append
   (if (twitter-use-https) "https" "http")
   "://" host path))

(define (%api-adapter status headers body)
  (let1 type (if-let1 ct (rfc822-header-ref headers "content-type")
               (match (mime-parse-content-type ct)
                 [(_ "xml" . _) 'xml]
                 [(_ "json" . _) 'json]
                 [(_ "html" . _) 'html])
               (error <twitter-api-error>
                      :status status :headers headers :body body
                      body))
    (unless (equal? status "200")
      (raise-api-error type status headers body))
    (ecase type
      ['xml
       (values (parse-xml-string body) headers)]
      ['json
       (values (parse-json-string body) headers)])))

(define (raise-api-error type status headers body)
  (ecase type
    ['xml
     (let1 body-sxml
         (guard (e (else #f))
           (parse-xml-string body))
       (error <twitter-api-error>
              :status status :headers headers :body body
              :body-sxml body-sxml
              (or (and body-sxml ((if-car-sxpath '(// error *text*)) body-sxml))
                  body)))]
    ['json
     (let1 body-json
         (guard (e (else #f))
           (parse-json-string body))
       (let ((aref assoc-ref)
             (vref vector-ref))
         (error <twitter-api-error>
                :status status :headers headers :body body
                :body-json body-json
                (or (and body-json
                         (guard (e (else #f))
                           (aref (vref (aref body-json "errors") 0) "message")))
                    body))))]
    ['html
     (error <twitter-api-error>
            :status status :headers headers :body body
            (parse-html-message body))]))

(define (check-api-error status headers body)
  (unless (equal? status "200")
    (or (and-let* ([ct (rfc822-header-ref headers "content-type")])
          (match (mime-parse-content-type ct)
            [(_ "xml" . _)
             (raise-api-error 'xml status headers body)]
            [(_ "json" . _)
             (raise-api-error 'json status headers body)]
            [(_ "html" . _)
             (raise-api-error 'html status headers body)]
            [_ #f]))
        (error <twitter-api-error>
               :status status :headers headers :body body
               body))))

;; select body elements text
(define (parse-html-message body)
  (let loop ((lines (string-split body "\n"))
			 (ret '()))
	(cond
     ((null? lines)
      (string-join (reverse ret) " "))
	 ((#/<h[0-9]>([^<]+)<\/h[0-9]>/ (car lines)) =>
	  (lambda (m)
        (loop (cdr lines) (cons (m 1) ret))))
     (else
      (loop (cdr lines) ret)))))

(define (retrieve-stream getter f . args)
  (let loop ((cursor "-1") (ids '()))
    (let* ([r (apply f (append args (list :cursor cursor)))]
           [next ((if-car-sxpath '(// next_cursor *text*)) r)]
           [ids (cons (getter r) ids)])
      (if (equal? next "0")
        (concatenate (reverse ids))
        (loop next ids)))))
