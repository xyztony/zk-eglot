# zk-eglot

This package provides Eglot integration for the [zk note-taking tool](https://github.com/zk-org/zk). All functionality is provided by the [zk LSP](https://zk-org.github.io/zk/config/config-lsp.html).

## Install

``` emacs-lisp
(use-package zk-eglot
  :vc (:url "https://github.com/xyztony/zk-eglot" :rev :newest)
  :hook
  (add-hook 'markdown-mode-hook
          (lambda ()
            (when (locate-dominating-file default-directory ".zk")
              (eglot-ensure)))))
```

