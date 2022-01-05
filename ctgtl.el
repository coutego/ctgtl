;;; ctgtl.el Quick track of time spent on tasks -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2021 Pedro Abelleira Seco
;;
;; Author: Pedro Abelleira Seco <https://github.com/pedroabelleiraseco>
;; Maintainer: Pedro Abelleira Seco <coutego@gmail.com>
;; Created: December 27, 2021
;; Modified: December 27, 2021
;; Version: 0.0.1
;; Keywords: convenience outlines
;; Homepage: https://github.com/coutego/ctgtl
;; Package-Requires: ((emacs "27.1"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;;
;; Org mode offers very advance capabilities for logging time spent on different
;; tasks and produce reports on it. Unfortunately, those are unusable for my use case,
;; so I decided to create a helper package for personal use to create prefefined
;; commands to quickly log time.
;;
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'dash)
(require 'f)
(require 'ht)
(require 'org)
(require 'org-element)
(require 'evil-commands)
(require 'org-ml)
(require 'hydra)
(require 'ts)

(defvar ctgtl-timestamp-format "%Y-%m-%d %H:%M:%S.%2N")
(defvar ctgtl-directory (f-join org-directory "ctgtl"))

(defun ctgtl-add-todo ()
  "Add a todo subheading to the current element in the log"
  (interactive)
  (let* ((bf (ctgtl--current-filename))
         (b  (find-file bf)))
    (with-current-buffer b
      (goto-char (point-max))
      (insert "\n** TODO ")
      (evil-append 1))))

(defun ctgtl-add-note ()
  "Add a note to the current element in the log"
  (interactive)
  (let* ((bf (ctgtl--current-filename))
         (b  (find-file bf))
         (w  (get-buffer-window b)))
    (with-current-buffer b
      (goto-char (point-max))
      (insert "\n** ")
      (evil-append 1))))

(defun ctgtl-go-current()
  "Go to the current task."
  (interactive)
  (let* ((bf (ctgtl--current-filename))
         (b  (find-file bf))
         (w  (get-buffer-window b)))
    (with-current-buffer b
      (goto-char (point-max)))))

(cl-defun ctgtl-add-entry (&rest entry)
  "Add a new entry in the log.

The arguments should be a plist with keys :project, :type, :title"
  (let ((b (find-file-noselect (ctgtl--current-filename))))
    (with-current-buffer b
      (goto-char (point-max))
      (insert "\n\n")
      (insert (apply #'ctgtl--create-entry entry))
      (insert "\n")
      (save-buffer)
      (goto-char (max-char)))))

(cl-defun ctgtl--create-entry-props (entry)
  (->> entry
       ht<-plist
       ((lambda (x) (ht-remove x :body) x)) ; remove :body from the properties
       (ht-amap (when value
                  (format ":%s: %s"
                          (format "CTGTL-%s" (ctgtl--keyword-to-string key))
                          value)))
       (--reduce (s-concat acc "\n" it))))

(defun ctgtl--keyword-to-string (key)
  (->> key
       (format "%s")
       (s-chop-prefix ":")
       upcase))

(cl-defun ctgtl--create-entry (&rest entry)
  (let* ((timestamp (ctgtl-create-timestamp))
         (id        (ctgtl--create-id))
         (title     (or (plist-get entry :title)
                        "Time log entry"))
         (tags      (or (plist-get entry :tags) ""))
         (body      (-if-let (body (plist-get entry :body)) body ""))
         (entry     (-concat (list :id id :timestamp timestamp) entry))
         (props     (ctgtl--create-entry-props entry)))
    ;; FIXME: check how many \n do we need to add bellow
    (format "* %s %s\n:PROPERTIES:\n%s\n:END:%s" title tags props body)))

(defun ctgtl-create-timestamp ()
  "Creates a timestamp to be logged"
  (format-time-string ctgtl-timestamp-format))

(defun ctgtl--create-id ()
  "Creates a new (unique) entry id."
  (format "%s%s"
          (upcase (s-word-initials (s-dashed-words (system-name))))
          (format-time-string "%Y%m%d%H%M%S%3N")))

(defun ctgtl--current-filename ()
  (let* ((name (format "%s.org" (format-time-string "%Y-%m-%d")))
         (year-month (format-time-string "%Y-%m")))
    (f-join ctgtl-directory year-month name)))

;; Parse log buffer

(defun ctgtl--export-csv-buffer (b fields &optional period)
  (->>
   (with-current-buffer b (org-ml-parse-this-buffer))
   (org-ml-get-children)
   (--filter (ctgtl--filter-headline-period it period))
   (--sort (ctgtl--parse-buffer-timestamp-sorter it other))
   ((lambda (xs) (-interleave xs (-concat (-drop 1 xs) '(nil)))))
   (-partition 2)
   (-map #'ctgtl--calculate-duration)
   (--map (ctgtl--export-csv-row fields it))
   (--reduce-from (and it (format "%s\n%s" acc it))
                  (s-join ", " fields))))

(defun ctgtl--filter-headline-period (h period)
  (if period
      (-let [(start end) period]
        (let* ((start (ts-apply :hour 0 :minute 0 :second 0 start))
               (end   (ts-apply :hour 23 :minute 59 :second 59.999 end))
               (time  (if-let ((tm (org-ml-headline-get-node-property "CTGTL-TIMESTAMP" h)))
                          (ts-parse tm)
                        nil)))
          (ts-format start);;
          (ts-format end)  ;; FIXME: remove
          (ts-format time) ;;
          (and time (ts<= start time) (ts>= end time))))
    t)) ;; else t

(cl-defun ctgtl--calculate-duration (p)
  (let* ((t1 (org-ml-headline-get-node-property "CTGTL-TIMESTAMP" (car p)))
         (t2 (org-ml-headline-get-node-property "CTGTL-TIMESTAMP" (cadr p)))
         (td (and t2
                  (time-subtract (apply #'encode-time (parse-time-string t2))
                                 (apply #'encode-time (parse-time-string t1)))))
         (ft (format "%s" (if td (float-time td) 0))))
    (org-ml-headline-set-node-property "CTGTL-DURATION" ft (car p))))


(defun ctgtl--parse-buffer-timestamp-sorter (h1 h2)
  (let ((t1 (org-ml-headline-get-node-property "CTGTL-TIMESTAMP" h1))
        (t2 (org-ml-headline-get-node-property "CTGTL-TIMESTAMP" h2)))
    (string< t1 t2)))

;;; CSV export

(defun ctgtl-export-csv (period fields &optional file)
  "Exports the logged time to CSV"
  (let ((file (or file (read-file-name "Select output file: " "~" "export.csv" nil))))
    (if (and file period)
        (ctgtl--export-csv-impl file fields period)
      (message "Export cancelled"))))

(defun ctgtl--encode-csv-field (s) (format "\"%s\"" (or s "")))

(defun ctgtl--export-csv-row (fields r)
  (->> fields
       (--map (format "CTGTL-%s" it))
       (--map (org-ml-headline-get-node-property it r))
       (-map #'ctgtl--encode-csv-field  )
       (--reduce (format "%s, %s" acc it))))

(defun ctgtl--export-csv-impl (file fields period)
  (let ((csv (ctgtl--export-csv-period-to-s fields period)))
    (if (and csv (< 0 (length (s-lines csv))))
        (progn
          (f-write csv 'utf-8 file)
          (message (format "Exported %d rows" (1- (length (s-lines csv))))))
      (message "No data to be exported"))))

(defun ctgtl--export-csv-period-to-s (fields period)
  (let ((fs (ctgtl--find-files-period period)))
    (with-temp-buffer
      (--each fs
        (when (f-exists-p it)
          (insert-buffer-substring (find-file-noselect it))))
      (ctgtl--export-csv-buffer (current-buffer) fields period))))

(defun ctgtl--find-files-period (period) ;; FIXME
  (-let (((start end) period))
    (message (format "start: %s, end: %s" start end))
    (list (ctgtl--current-filename))))

(provide 'ctgtl)
;;; ctgtl.el ends here
