(define-module net.twitter.user
  (use net.twitter.core)
  (export
   user-show/sxml
   user-lookup/sxml
   user-search/sxml
   user-suggestions/sxml
   user-suggestions/category/sxml))
(select-module net.twitter.user)

;; cred can be #f.
(define (user-show/sxml cred :key (id #f) (user-id #f) (screen-name #f)
                        :allow-other-keys _keys)
  (call/oauth->sxml cred 'get #`"/1/users/show.xml"
                    (api-params _keys id user-id screen-name)))

(define (user-lookup/sxml cred :key (user-ids '()) (screen-names '())
                          (include-entities #f) (skip-status #f)
                          :allow-other-keys _keys)
  (let ((user-id (and (pair? user-ids) (string-join (map x->string user-ids) ",")))
        (screen-name (and (pair? screen-names) (string-join screen-names ","))))
    (call/oauth->sxml cred 'post #`"/1/users/lookup.xml"
                      (api-params _keys user-id screen-name
                                    include-entities skip-status))))

(define (user-search/sxml cred q :key (per-page #f) (page #f)
                          (include-entities #f) (skip-status #f)
                          :allow-other-keys _keys)
  (call/oauth->sxml cred 'get "/1/users/search.xml"
                    (api-params _keys q per-page page
                                  include-entities skip-status)))

;; CRED can be #f
(define (user-suggestions/sxml cred :key (lang #f)
                               :allow-other-keys _keys)
  (call/oauth->sxml cred 'get "/1/users/suggestions.xml"
                    (api-params _keys lang)))

;; CRED can be #f
(define (user-suggestions/category/sxml cred slug :key (lang #f)
                                        :allow-other-keys _keys)
  (call/oauth->sxml cred 'get #`"/1/users/suggestions/,|slug|.xml"
                    (api-params _keys lang)))

