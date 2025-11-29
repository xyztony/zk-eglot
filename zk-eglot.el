;;; zk-eglot.el --- Eglot integration for zk note-taking -*- lexical-binding: t; -*-

;; Copyright (C) 2025 xyztony

;; Author: xyztony
;; Maintainer: xyztony
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (eglot "1.15"))
;; Keywords: convenience, notes, tools, lsp
;; URL: https://github.com/xyztony/zk-eglot

;;; Commentary:

;; This package provides Eglot integration for the zk note-taking tool.
;; It enables LSP-powered features like note creation, linking, searching,
;; and indexing directly from Emacs through the zk LSP server.
;;
;; The zk tool is a plain text note-taking assistant:
;; https://github.com/zk-org/zk
;;
;; For editor integration details, see:
;; https://zk-org.github.io/zk/tips/editors-integration.html
;;
;; Usage:
;; (add-hook 'markdown-mode-hook #'zk-mode-maybe-enable)
;;
;; With use-package:
;; (use-package zk-eglot
;;   :hook (markdown-mode . zk-mode-maybe-enable)
;;   :bind (:map zk-mode-map
;;          ("C-c z i" . zk-index)
;;          ("C-c z n" . zk-new)
;;          ("C-c z l" . zk-list)
;;          ("C-c z r" . zk-list-recent)
;;          ("C-c z k" . zk-link)))
;;
;; Define custom zk aliases with `zk-define-new`:
;; (zk-define-new zk-new-daily :dir "journal/daily")

;;; Code:

(require 'eglot)
(require 'cl-lib)
(require 'iso8601)

(defgroup zk-eglot nil
  "Eglot integration for the zk note-taking tool."
  :group 'tools
  :prefix "zk-")

(defcustom zk-mode-auto-eglot t
  "When non-nil, automatically start Eglot when `zk-mode' is enabled."
  :type 'boolean
  :group 'zk-eglot)

(defvar zk-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for `zk-mode'.")

;;;###autoload
(define-minor-mode zk-mode
  "Minor mode for zk with Eglot.
Provides keybindings for zk commands when enabled.

When `zk-mode-auto-eglot' is non-nil, automatically starts Eglot."
  :lighter " zk"
  :keymap zk-mode-map
  :group 'zk-eglot
  (when (and zk-mode zk-mode-auto-eglot)
    (eglot-ensure)))

;;;###autoload
(defun zk-mode-maybe-enable ()
  "Enable `zk-mode' if current buffer is in a zk notebook.
A zk notebook is detected by the presence of a .zk directory."
  (when (locate-dominating-file default-directory ".zk")
    (zk-mode 1)))

;; Add zk to the list of LSP servers that Eglot knows about
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(markdown-mode . ("zk" "lsp"))))

;;; Data layer helpers

(defun zk--get-source-buffer ()
  "Get the buffer with eglot context for zk commands."
  (current-buffer))

(defun zk--ensure-visiting-file (&optional buffer)
  "Ensure BUFFER (or current buffer) is visiting a file.
Signal user-error if not."
  (unless (buffer-file-name buffer)
    (user-error "Buffer must be visiting a file")))

(defun zk--exec (cmd &optional args buffer)
  "Execute LSP command CMD with optional ARGS in BUFFER.
BUFFER defaults to the source buffer.
Returns the result from eglot-execute-command."
  (let ((buf (or buffer (zk--get-source-buffer))))
    (with-current-buffer buf
      (zk--ensure-visiting-file buf)
      (eglot-execute-command
       (eglot--current-server-or-lose)
       cmd
       (if args
           (vector (buffer-file-name) args)
         (vector (buffer-file-name)))))))

(defun zk--list-notes (opts &optional buffer)
  "List notes with OPTS plist in BUFFER (or source buffer)."
  (zk--exec "zk.list" opts buffer))

(defun zk--list-tags (&optional opts)
  "List tags with OPTS plist.
OPTS defaults to sorting by note-count descending."
  (let ((res (zk--exec "zk.tag.list"
                       (or opts '(:sort ["note-count-"])))))
    (if (vectorp res) (append res nil) res)))

(defun zk--get-all-tags ()
  "Fetch all tags from the zk notebook."
  (mapcar (lambda (tag) (plist-get tag :name)) (zk--list-tags)))

(defun zk--note-title (note)
  "Extract title from NOTE plist, returning safe default."
  (or (plist-get note :title) "Untitled"))

(defun zk--note-tags-list (note)
  "Extract tags from NOTE plist as a list of strings.
Handles both vector and list formats."
  (let ((tags (plist-get note :tags)))
    (cond ((vectorp tags) (append tags nil))
          ((listp tags) tags)
          (t nil))))

(defun zk--format-datetime (datetime-str)
  "Format DATETIME-STR to MM/DD/YY HH:mm:ss format.
If DATETIME-STR is nil or cannot be parsed, return it as-is."
  (if (and datetime-str (stringp datetime-str))
      (condition-case err
          (let ((decoded-time (iso8601-parse datetime-str)))
            (format-time-string "%m/%d/%y %H:%M:%S" (encode-time decoded-time)))
        (error
         (message "zk-eglot: failed to parse datetime %S (%s)" datetime-str err)
         datetime-str))
    datetime-str))

(defun zk--build-list-opts (query use-tags)
  "Build zk.list options and description for QUERY and USE-TAGS.
Returns (opts . description) where opts is a plist for zk.list
and description is a user-facing string describing the query."
  (let* ((opts (list :select ["title" "path" "tags" "created"]))
         (desc nil))
    (when (and query (not (string-empty-p query)))
      (plist-put opts :match (vector query)))
    (when use-tags
      (let* ((all (zk--get-all-tags))
             (tags (completing-read-multiple
                    "Tags (comma-separated, RET when done): "
                    all
                    nil
                    nil
                    nil
                    'zk-tag-history)))
        (plist-put opts :tags (vconcat tags))
        (setq desc (if (plist-get opts :match)
                       (format "tags: %s, match: %s"
                               (mapconcat #'identity tags ", ")
                               query)
                     (format "tags: %s" (mapconcat #'identity tags ", "))))))
    (cons opts (or desc (format "match: %s" query)))))

(cl-defun zk--notes->candidates (notes &key include-tags include-created include-modified)
  "Build minibuffer candidates from NOTES.
Returns alist of (display . path).
INCLUDE-TAGS, INCLUDE-CREATED, INCLUDE-MODIFIED control which metadata to show."
  (mapcar (lambda (note)
            (let* ((title (zk--note-title note))
                   (path (plist-get note :path))
                   (bits (list title
                               (when (and include-tags (zk--note-tags-list note))
                                 (format " [%s]" (mapconcat #'identity (zk--note-tags-list note) ", ")))
                               (when (and include-created (plist-get note :created))
                                 (format " (%s)" (zk--format-datetime (plist-get note :created))))
                               (when (and include-modified (plist-get note :modified))
                                 (format " (%s)" (zk--format-datetime (plist-get note :modified)))))))
              (cons (apply #'concat (delq nil bits)) path)))
          notes))

;;;###autoload
(defun zk-index ()
  "Index the current zk notebook."
  (interactive)
  (zk--exec "zk.index"))

;;;###autoload
(defun zk-new-create (&rest args)
  "Create a new zk note by calling the LSP command \"zk.new\".
ARGS is a property list of options accepted by zk.new, e.g.:
  :title STRING
  :dir STRING
  :template STRING
and any other keys the server supports.

Returns the created file path (string) on success, or nil on failure.
Signals a user-error if ARGS is not a plist with keyword keys."
  (unless (and (cl-evenp (length args))
               (cl-loop for (k _) on args by #'cddr always (keywordp k)))
    (user-error "zk-new-create: ARGS must be a plist of keyword keys (got: %S)" args))
  (condition-case err
      (let* ((res  (zk--exec "zk.new" args))
             (path (plist-get res :path)))
        (if (and (stringp path) (not (string= path "")))
            path
          (message "zk-eglot: zk.new returned no :path (response: %S)" res)
          nil))
    (error
     (message "zk-eglot: zk.new failed: %s" (error-message-string err))
     nil)))

;;;###autoload
(defmacro zk-define-new (name &rest defaults)
  "Define an interactive command NAME to create a zk note via zk.new.

DEFAULTS is a plist of keyword args passed to zk.new (e.g., :dir, :template).
If DEFAULTS does not include :title, the command will prompt for a title.

Example: (zk-define-new zk-new-daily :dir \"journal/daily\")"
  (let* ((have-title (cl-loop for (k _) on defaults by #'cddr thereis (eq k :title)))
         (doc (format "Create a zk note via zk.new with defaults: %S" defaults)))
    `(defun ,name ,(if have-title '() '(title))
       ,doc
       ,(if have-title
            '(interactive)
          '(interactive "sNote title: "))
       (let* ((defaults (list ,@defaults))
              (args (if ,have-title defaults (append defaults (list :title title))))
              (path (apply #'zk-new-create args)))
         (if path
             (find-file path)
           (user-error "Failed to create note"))))))

;;;###autoload
(defun zk-new (title)
  "Create a new zk note with TITLE and visit it."
  (interactive "sNote title: ")
  (if-let ((path (zk-new-create :title title)))
      (find-file path)
    (user-error "Failed to create note")))

;;;###autoload
(defun zk-list (query &optional use-tags)
  "List notes matching QUERY.
By default, QUERY is a full-text search string.
With prefix argument (C-u), prompt for tags to filter by, then optionally a query string."
  (interactive
   (if current-prefix-arg
       (list (read-string "Search notes (optional): ") t)
     (list (read-string "Search notes: ") nil)))
  (let* ((source-buffer (zk--get-source-buffer))
         (opts-and-desc (with-current-buffer source-buffer
                          (zk--build-list-opts query use-tags)))
         (opts (car opts-and-desc))
         (desc (cdr opts-and-desc))
         (notes (zk--list-notes opts source-buffer))
         (candidates (zk--notes->candidates notes
                                            :include-tags t
                                            :include-created t)))
    (if (null candidates)
        (message "No notes found")
      (let* ((completion-extra-properties '(:category file))
             (choice (completing-read (format "Notes (%s): " desc)
                                      (mapcar #'car candidates) nil t nil 'zk-list-history))
             (selected (cdr (assoc choice candidates))))
        (when selected
          (find-file selected))))))

;;;###autoload
(defun zk-link ()
  "Insert a link to another note at point."
  (interactive)
  (zk--ensure-visiting-file)
  (let* ((current-file (buffer-file-name))
         (notes (zk--exec "zk.list" '(:select ["title" "path"])))
         (note-alist (mapcar (lambda (note)
                               (cons (or (plist-get note :title) "Untitled")
                                     (plist-get note :path)))
                             notes))
         (selected-title (completing-read "Link to note: " note-alist))
         (selected-path (cdr (assoc selected-title note-alist)))
         (line (1- (line-number-at-pos)))
         (char (current-column))
         (location `(:uri ,(concat "file://" current-file)
                          :range (:start (:line ,line :character ,char)
                                         :end (:line ,line :character ,char)))))
    (zk--exec "zk.link" `(:path ,selected-path :location ,location))))

;;;###autoload
(defun zk-list-recent ()
  "List recently modified notes."
  (interactive)
  (let* ((source-buffer (zk--get-source-buffer))
         (notes (zk--list-notes '(:select ["title" "path" "modified"]
                                          :sort ["modified-"]
                                          :limit 20)
                                source-buffer))
         (candidates (zk--notes->candidates notes :include-modified t)))
    (if (null candidates)
        (message "No recent notes found")
      (let* ((completion-extra-properties '(:category file))
             (choice (completing-read "Recent notes: "
                                      (mapcar #'car candidates) nil t nil 'zk-list-recent-history))
             (selected (cdr (assoc choice candidates))))
        (when selected
          (find-file selected))))))

(provide 'zk-eglot)

;;; zk-eglot.el ends here
