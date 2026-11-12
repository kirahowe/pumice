;;; install-optional.el --- Install the optional packages for CI -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with `emacs --batch -l test/install-optional.el'.  It installs the
;; packages pumice can use but does not need, so that the tests which
;; exercise them have something to run against.

;;; Code:

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(package-refresh-contents)
(dolist (name '(evil consult corfu markdown-mode))
  (package-install name))

;;; install-optional.el ends here
