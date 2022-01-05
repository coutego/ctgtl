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
  "Go to the current task (end of the log file)."
  (interactive)
  (let* ((bf (ctgtl--current-filename))
         (b  (find-file bf))
         (w  (get-buffer-window b)))
    (with-current-buffer b
      (goto-char (point-max)))))

(cl-defun ctgtl-add-entry (&rest entry)
  "Add a new entry in the log.

The arguments should be a plist with keys :project, :type, :title."
  (let ((b (find-file-noselect (ctgtl--current-filename))))
    (with-current-buffer b
      (goto-char (point-max))
      (insert "\n\n")
      (insert (apply #'ctgtl--create-entry entry))
      (insert "\n")
      (save-buffer)
      (goto-char (max-char)))))

(cl-defun ctgtl--create-entry-props (entry)
  "Create the properties section for a given entry."
  (->> entry
       ht<-plist
       ((lambda (x) (ht-remove x :body) x)) ; remove :body from the properties
       (ht-amap (when value
                  (format ":%s: %s"
                          (format "CTGTL-%s" (ctgtl--keyword-to-string key))
                          value)))
       (--reduce (s-concat acc "\n" it))))

(defun ctgtl--keyword-to-string (key)
  "Convert a key to a string (upper case, without the ':')."
  (->> key
       (format "%s")
       (s-chop-prefix ":")
       upcase))

(cl-defun ctgtl--create-entry (&rest entry)
  "Create an entry from the given list of properties."
  (let* ((timestamp (ctgtl-create-timestamp))
         (id        (ctgtl--create-id))
         (title     (or (plist-get entry :title)
                        "Time log entry"))
         (tags      (or (plist-get entry :tags) ""))
         (body      (-if-let (body (plist-get entry :body)) body ""))
         (entry     (-concat (list :id id :timestamp timestamp) entry))
         (props     (ctgtl--create-entry-props entry)))
    ;; FIXME: check how many \n do we need to add below
    (format "* %s %s\n:PROPERTIES:\n%s\n:END:%s" title tags props body)))

(defun ctgtl-create-timestamp ()
  "Create a timestamp to be logged."
  (format-time-string ctgtl-timestamp-format))

(defun ctgtl--create-id ()
  "Create a new (unique) entry id."
  (format "%s%s"
          (upcase (s-word-initials (s-dashed-words (system-name))))
          (format-time-string "%Y%m%d%H%M%S%3N")))

(defun ctgtl--current-filename ()
  "Return the filename for the current log file."
  (let* ((name (format "%s.org" (format-time-string "%Y-%m-%d")))
         (year-month (format-time-string "%Y-%m")))
    (f-join ctgtl-directory year-month name)))

(defun ctgtl--filter-headline-period (h period)
  "Filter function for headlines and a given period.

Return t if the heading H is inside PERIOD."
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
  "Calculate duration of a given period P."
  (let* ((t1 (org-ml-headline-get-node-property "CTGTL-TIMESTAMP" (car p)))
         (t2 (org-ml-headline-get-node-property "CTGTL-TIMESTAMP" (cadr p)))
         (td (and t2
                  (time-subtract (apply #'encode-time (parse-time-string t2))
                                 (apply #'encode-time (parse-time-string t1)))))
         (ft (format "%s" (if td (float-time td) 0))))
    (org-ml-headline-set-node-property "CTGTL-DURATION" ft (car p))))

(defun ctgtl--parse-buffer-timestamp-sorter (h1 h2)
  "Sort function for headings, based on their timestamps.

Return t if h2 is posterior to h1"
  (let ((t1 (org-ml-headline-get-node-property "CTGTL-TIMESTAMP" h1))
        (t2 (org-ml-headline-get-node-property "CTGTL-TIMESTAMP" h2)))
    (string< t1 t2)))

;;; Org export
(defun ctgtl-export-org (period groups &optional file)
  "Export the logged time to CSV.

PERIOD is a list of two elements corresponding to the start and end dates.
These two elements must be dates generated with the ts library.
GROUPS is a list of criteria to group the results by. Each of the elements
of GROUPS must be either a string or a cons cell with a string describing
the group as the first element and a function that, given an element, gives
the value to group by."
  (let ((file (or file (read-file-name "Select output file: " "~" "export.org" nil))))
    (if (and file period)
        (message "Wrote %s lines"
                 (or (ctgtl--export-org-impl file groups period)
                     0))
      (message "Export cancelled"))))

(defun ctgtl--export-org-impl (file groups period)
  "Export the log entries for the given PERIOD to FILE, grouped as GROUPS.
Return the number of lines written to the file"
  (->> (ctgtl--get-entries-period period)
       (ctgtl--group-entries groups)
       (ctgtl--grouped-entries-to-org-text)
       (ctgtl--write-file file)))

(defun ctgtl--get-entries-period (period)
  "Return all the log entries for the given PERIOD, as headlines."
  (->> period
       (ctgtl--find-files-period)
       (ctgtl--concatenate-file-contents)
       (ctgtl--org-string-to-headlines)))

(defun ctgtl--org-string-to-headlines (s)
  "Parse the string s and return a list of headlines."
  (with-temp-buffer
    (insert s)
    (org-ml-parse-headlines 'all)))

(defun ctgtl--find-files-period (_period)
  "Find the log files for the given period.

FIXME the current implementation returns all files, which is wasteful."
  (f-files ctgtl-directory (lambda (f) (s-ends-with-p ".org" f)) t))

(defun ctgtl--concatenate-file-contents (files)
  "Concatenate the content of the FILES on a single string."
  (with-temp-buffer
    (--each files
      (when (f-exists-p it)
        (insert-buffer-substring (find-file-noselect it))))
    (buffer-string)))

(defun ctgtl--group-entries (_groups entries)
  "Group the entries by the given GROUPS.

FIXME: this is not currently implemented."
  entries)

(defun ctgtl--grouped-entries-to-org-text (entries)
  (org-ml-to-string entries))

(defun ctgtl--write-file (file text)
  "Write the TEXT to the given FILE, returning the number of rows written."
  (f-write-text text 'utf-8 file)
  (-> text (s-lines) (length)))

;;; CSV export
(defun ctgtl-export-csv (period fields &optional file)
  "Export the logged time to CSV.
PERIOD is a time record from the ts package
FIELDS is a list of string with the names of the fields to be
exported (don't add the 'CTGL' prefix)
If FILE is not specified, the user will be prompted for one"
  (let ((file (or file (read-file-name "Select output file: " "~" "export.csv" nil))))
    (if (and file period)
        (message "%s records written"
                 (or
                  (ctgtl--export-csv-impl file fields period)
                  0))
      (message "Export cancelled"))))

(defun ctgtl--export-csv-impl (file fields period)
  (->> (ctgtl--get-entries-period period)
       (ctgtl--entries-to-csv fields)
       (ctgtl--write-file file)))

(defun ctgtl--entries-to-csv (fields entries)
  "Transform a list of entries to a CSV string (with headlines and newlines)"
  (->> entries
       (--map (ctgtl--entry-to-csv it fields))
       (-concat (list (s-join ", " fields)))
       (s-join "\n")))

(defun ctgtl--entry-to-csv (entry fields)
  "Convert a entry (headline) to a csv row (as a string without newline)"
  (->> fields
       (--map (format "CTGTL-%s" it))
       (--map (org-ml-headline-get-node-property it entry))
       (-map #'ctgtl--encode-csv-field)
       (--reduce (format "%s, %s" acc it))))

(defun ctgtl--encode-csv-field (s) (format "\"%s\"" (or s "")))

(provide 'ctgtl)
;;; ctgtl.el ends here
