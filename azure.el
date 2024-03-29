;;; azure.el -*- lexical-binding: t; -*-

(setq lexical-binding t)

(require 'json)
(require 'log4e)
(require 'url)
(require 'transient)
(require 'ivy)
(require 'aio)

(setq lexical-binding t)

(log4e:deflogger "azure" "%t [%l] %m" "%H:%M:%S" '((fatal . "fatal")
						      (error . "error")
						      (warn  . "warn")
						      (info  . "info")
						      (debug . "debug")
						      (trace . "trace")))
(setq log4e--log-buffer-leetcode "*azure-log*")

(defun json-parse (str)
  "parse json from str as hashtable"
    (let ((json-object-type 'hash-table)
	(json-array-type 'list)
	(json-key-type 'string))
    (json-read-from-string str)))

(aio-defun get-request (url)
  (let* ((url-request-method "GET")
         (resp (aio-await (aio-url-retrieve url)))
	 (buf (cdr resp)))
    (with-current-buffer buf
      (buffer-string))))

(defun azure-func-start ()
  "Start Functions server in the background"
  (interactive)
  (when (boundp 'functions-server)
    (message "Closing existing server")
    (azure-func-stop))
  (message "Starting Functions server...")
  (setq endpoints nil)
  (with-current-buffer (generate-new-buffer "*Azure Functions*")
    ;; NOTE: c# and ts use a different command
    (setq functions-server (start-process "Azure Functions Server" (current-buffer) "func" "start")))
  (set-process-sentinel functions-server 'func-cleanup)
  (set-process-filter functions-server 'insertion-filter))

(defun func-cleanup (proc str)
  "Kill func buffer when process completed"
  (when (or (null (process-status (process-name proc)))
	(= (process-status (process-name proc)) 'exit))
    (kill-buffer (process-buffer proc))))

(aio-defun azure-func-query ()
  (interactive)
  (cond
    ((not (boundp 'functions-server))
     (message "Start functions server first with M-x azure-func-start RET"))
    ((null endpoints)
     (message "No endpoints logged yet; wait a few more seconds"))
    (t
     (aio-await (query-and-display endpoints)))))

(aio-defun query-and-display (endpoints)
  (let* ((endpoint (ivy-read "Endpoint to query: " endpoints))
	 (params (read-string (concat "Query: " endpoint "/"))))
  (message (aio-await (get-request (concat endpoint "/" params))))))

(defun insertion-filter (proc string)
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((moving (= (point) (process-mark proc))))
        (save-excursion
          ;; Insert the text, advancing the process marker.
          (goto-char (process-mark proc))
          (insert string)
	  (set-endpoint-if-present string)
          (set-marker (process-mark proc) (point)))
        (when moving (goto-char (process-mark proc)))))))

(defun re-seq (regexp string)
  "Get a list of all regexp matches in a string"
  (save-match-data
    (let ((pos 0)
          matches)
      (while (string-match regexp string pos)
        (push (match-string 0 string) matches)
        (setq pos (match-end 0)))
      matches)))

(defun set-endpoint-if-present (string)
  (let*
    ((match (string-match "^Http Functions:\n\n\\([ \t]*.+: \\[.*\\] *http.+\n\n\\)+" string))
     (endpoints-str (ignore-errors (match-string 0 string)))
     (epoints (re-seq "https?://.+" endpoints-str)))
    (when (not (null epoints))
      (setq endpoints epoints))))

(defun azure-func-stop ()
  "Stop the Functions server"
  (interactive)
  (when (boundp 'functions-server)
    (kill-buffer (process-buffer functions-server))
    (delete-process functions-server)
    (makunbound 'functions-server)
    (setq endpoints nil))
  't)

;; Remove any resources of "null" kind
(defun filter-resources (resources)
  (seq-filter (lambda (x) (gethash "kind" x)) resources))

;; Get detailed information for any resource given its id
(defun get-resource-details (id)
  (json-parse (shell-command-to-string (format "az resource show --ids %s" id))))

;; The status field is called different things depending on the type of resource
;; This function could be optimized by eagerly exiting when finding a valid status field
(defun get-status-from-details (details)
  (let* ((properties (gethash "properties" details))
         (status (gethash "status" properties))
         (state (gethash "state" properties))
         (primary (gethash "statusOfPrimary" properties)))
    (cond (status status)
          (state state)
          (primary primary)
          (t "N/A"))))

;; Add status of a resource to its hash table
(defun enrich-resource-status (resource-hash-table)
  (let* ((id (gethash "id" resource-hash-table))
         (details (get-resource-details id))
         (status (get-status-from-details details)))
    (puthash "status" status resource-hash-table)
    resource-hash-table))

;; Enrich a list of resources with data only visible in their detailed views
(defun enrich-resources (resources)
  (mapcar (lambda (x) (enrich-resource-status x)) resources))

;; TODO: This fails if the az command returns an empty array
(defun run-resource-list (&optional args)
  (json-parse (shell-command-to-string (concat "az resource list " (mapconcat 'identity args " ")))))

;; Fetch resource list with az, then format result as a vector in the format tabulated-list-mode can read
(defun get-resources (&optional args)
  (let ((res (enrich-resources (filter-resources (run-resource-list args)))))
    (mapcar (lambda (x) (vector (gethash "name" x)
                                (gethash "status" x)
                                (gethash "kind" x)
                                (gethash "location" x)
                                (gethash "resourceGroup" x))
              ) res)))

(defun update-resources (&optional args)
  (interactive
   (list (transient-args 'azure-resource-transient)))
  (let ((rows (mapcar (lambda (x) `(nil ,x)) (get-resources args))))
    (update-table-entries rows)))

;; Create azure major made based on tabulated list
(define-derived-mode azure-mode tabulated-list-mode "Azure"
  "Azure Mode"
  (use-local-map azure-map)
  (let ((columns [("Resource" 20) ("Status" 20) ("Kind" 20) ("Location" 20) ("Resource Group" 20)])
        (rows (mapcar (lambda (x) `(nil ,x)) (get-resources))))
    (setq tabulated-list-format columns)
    (setq tabulated-list-entries rows)
    (tabulated-list-init-header)
    (tabulated-list-print)))

(defun update-table ()
  (interactive)
  (update-table-entries (list `(nil ["a" "b" "c" "d" "e"]))))

(defun update-table-entries (entries)
  (setq tabulated-list-entries entries)
  (tabulated-list-print))

;; Interactive function to launch azel
(defun azure ()
  (interactive)
  (switch-to-buffer "*azure*")
  (azure-mode))

;; Just a temporary test function to test transient functionality
(defun test-popup (&optional args)
  (interactive
   (list (transient-args 'azure-transient)))
  (message "Args: %s" args))

(aio-defun query-function-main ()
  "Start functions server if not started, then prompt to query the endpoint."
  (interactive)
  (when (not (boundp 'functions-server))
    (azure-func-start)
    ;; wait for endpoint to populate
    (sleep-for 2 0))
  (aio-await (azure-func-query)))

(defun query-function-main-sync ()
  (interactive)
  (aio-wait-for (query-function-main)))

;; This unecessarily refetches all the resources again, can be optimzed to retrieve this info on startup
(defun get-locations ()
  "Get all resource locations"
  (let* ((resources (filter-resources (run-resource-list)))
        (locations (mapcar (lambda (x) (gethash "location" x)) resources)))
    (seq-uniq locations)))

(transient-define-infix resource-transient:--location ()
  "Location transient infix"
  :description "Location"
  :shortarg "-l"
  :argument "--location="
  :class 'transient-option
  :choices (get-locations))

(define-transient-command azure-function-transient ()
  "Azure Functions Commands"
  ["Actions"
   ("f" "Query Function" query-function-main-sync)])

;; TODO: Some combinations aren't allowed e.g. tag and anything else
(define-transient-command azure-resource-transient ()
  "Azure Resource Commands"
  ["Arguments"
   ("-s" "Subscription" "--subscription=")
   ("-g" "Resource Group" "--resource-group=")
   (resource-transient:--location)
   ("-t" "Tag" "--tag=")
   ("-r" "Resource Type" "--resource-type=")
   ("-n" "Name" "--name=")
   ("-p" "Namespace" "--namespace=")]
  ["Actions"
   ("r" "Display Resources" update-resources)
   ("u" "Update with example data" update-table)])

(define-transient-command azure-transient ()
  "Azure Command Overview"
  ["Actions"
   ("r" "Resources" azure-resource-transient)
   ("f" "Functions" azure-function-transient)])

(defvar azure-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "?") 'azure-transient)
    (define-key map (kbd "r") 'azure-resource-transient)
    (define-key map (kbd "f") 'azure-function-transient)
    map))
