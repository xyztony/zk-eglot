# zk-eglot

This package provides Eglot integration for the [zk note-taking tool](https://github.com/zk-org/zk). All functionality is provided by the [zk LSP](https://zk-org.github.io/zk/config/config-lsp.html).

## Install

``` emacs-lisp
(use-package zk-eglot
  :vc (:url "https://github.com/xyztony/zk-eglot" :rev :newest)
  :hook (markdown-mode . zk-mode-maybe-enable)
  :bind (:map zk-mode-map
         ("C-c z i" . zk-index)
         ("C-c z n" . zk-new)
         ("C-c z l" . zk-list)
         ("C-c z r" . zk-list-recent)
         ("C-c z k" . zk-link)))
```

