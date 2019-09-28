
;; Copyright (C) 2019 Philipp Kutin

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; TODO: add license file.

(require 'flycheck)

;; Usage (for now):
;;  (load "/path/to/.../ljclang-wcc-flycheck.el")

;; TODO:
;;  make usable with 'require'.

;; NOTE/TODO this may not yet work as intended: Flycheck intercepts a non-zero exit status
;;  from wcc-client and displays a lengthy message. Note though that 'C-c ! v' does show
;;   - wcc-client check: failed (for not further known reasons)
;;  as expected if the server is not running. So, it seems partially working.
(defun ljclang-wcc-check-diags-request ()
  (let*
      ;; NOTE: with-demoted-errors did not work reliably in interactive testing, either
      ;; erroring or giving back nil from one call to the next. (However, that state seemed
      ;; sticky: once it was the nil, it was nil forever.)
      ;; What's up with it? Emacs bug?
      ;;
      ;; FIXME: address the above. It is quite crucial to get precise information here.
      ((lines (ignore-errors (process-lines "wcc-client" "-c")))
       (all-ok (equal lines '("OK"))))
    all-ok)
)

(flycheck-define-checker c/c++-wcc
  "A C/C++ syntax checker using watch_compile_commands.

See URL `https://github.com/helixhorned/ljclang/tree/staging'."
  ;; TODO: remove 'staging' once it is merged to master.
  :command ("wcc-client" "diags" source-original)

  :error-patterns  ; same as for 'c/c++-clang' checker, but with '<stdin>' removed.
  ((info line-start (file-name) ":" line ":" column
         ": note: " (optional (message)) line-end)
   (warning line-start (file-name) ":" line ":" column
            ": warning: " (optional (message)) line-end)
   (error line-start (file-name) ":" line ":" column
          ": " (or "fatal error" "error") ": " (optional (message)) line-end))

  :modes (c-mode c++-mode)
  :predicate flycheck-buffer-saved-p

  :verify
  (lambda (_)
    (let ((all-ok (ljclang-wcc-check-diags-request)))
      (list
       (flycheck-verification-result-new
        :label "wcc-client check"
        :message (if all-ok "success" "failed (for not further known reasons)")
        :face (if all-ok 'success '(bold error))))))
)
