;; guix build -L modules -f tests/image.scm -r hello.squashfs
;; apptainer run hello.squashfs                           # Hello, world!
;; apptainer run hello.squashfs -g Bonjour                # Bonjour
;; apptainer exec hello.squashfs sh -c 'echo "$QUOTED"'   # it's "quoted": $HOME `date` \
;; apptainer exec --env GREETING=hi hello.squashfs sh -c 'echo "$GREETING"'   # hi
(use-modules (apptainer-tools)
             (gnu packages base))

(apptainer-image
 (name "hello")
 (packages (list hello))
 (run-script "exec hello \"$@\"")
 (environment '(("QUOTED" . "it's \"quoted\": $HOME `date` \\")))
 (compression-level 1))
