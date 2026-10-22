(define-module (apptainer-tools image)
  #:use-module (guix gexp)
  #:use-module (guix profiles)
  #:use-module (guix records)
  #:use-module (gnu packages bash)
  #:use-module (apptainer-tools layer)
  #:use-module (apptainer-tools store-squashfs)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (apptainer-image
            apptainer-image?
            apptainer-image-name
            apptainer-image-packages
            apptainer-image-layers
            apptainer-image-run-script
            apptainer-image-environment
            apptainer-image-compression
            apptainer-image-compression-level))

;; An image for 'apptainer run': a squashfs holding the closure of a profile
;; of PACKAGES and of the packages of LAYERS, minus the store items that
;; LAYERS hold.
(define-record-type* <apptainer-image>
  apptainer-image make-apptainer-image
  apptainer-image?
  (name              apptainer-image-name)
  (packages          apptainer-image-packages
                     (default '()))
  ;; <apptainer-layer> records; the image runs only with them as overlays,
  ;; and says so otherwise.
  (layers            apptainer-image-layers
                     (default '()))
  ;; Shell code that 'apptainer run' executes with /bin/sh.
  (run-script        apptainer-image-run-script
                     (default "exec /bin/sh \"$@\""))
  ;; Alist of the variables set in every 'apptainer run', 'exec' and 'shell'.
  (environment       apptainer-image-environment
                     (default '()))
  ;; mksquashfs compressor: gzip, zstd, xz, lz4 or lzo.
  (compression       apptainer-image-compression
                     (default "gzip"))
  ;; 1-9 for gzip and lzo, 1-22 for zstd; #f keeps mksquashfs's default.
  (compression-level apptainer-image-compression-level
                     (default #f)))

(define (image-profile image)
  (profile
   (content (packages->manifest
             (delete-duplicates
              (append (apptainer-image-packages image)
                      (append-map apptainer-layer-packages
                                  (apptainer-image-layers image)))
              eq?)))))

;; Apptainer reads env files with its own shell interpreter, which keeps the
;; backslash of an unquoted \' ('it'\''s' comes out as it\'s).  Double quotes
;; with \ " $ ` escaped read as in sh.
(define (shell-quote value)
  (string-append "\""
                 (string-concatenate
                  (map (lambda (char)
                         (if (memv char '(#\\ #\" #\$ #\`))
                             (string #\\ char)
                             (string char)))
                       (string->list value)))
                 "\""))

(define (environment-exports environment)
  (string-concatenate
   (map (match-lambda
          ((name . value)
           (string-append "export " name "=" (shell-quote value) "\n")))
        environment)))

(define (layer-check layer)
  "Return a gexp for the shell code that stops the container when LAYER is
not mounted."
  #~(let ((file (basename #$layer)))
      (string-append
       "if [ ! -e /.layers/" #$(apptainer-layer-marker layer) " ]; then\n"
       "  echo \"error: this image needs the layer " file
       ": run it with --overlay " file ":ro\" >&2\n"
       "  exit 1\n"
       "fi\n")))

(define (image-tree image profile)
  (match-record image <apptainer-image>
    (name layers run-script environment)
    (computed-file
     (string-append name "-tree")
     (with-imported-modules '((guix build utils))
       #~(begin
           (use-modules (guix build utils)
                        (ice-9 ftw)
                        (srfi srfi-26))

           (define (write-file file text)
             (call-with-output-file (string-append #$output "/" file)
               (cut display text <>)))

           (define profile-bin
             (string-append #$profile "/bin"))

           (mkdir-p (string-append #$output "/bin"))
           (for-each (lambda (file)
                       (symlink (string-append profile-bin "/" file)
                                (string-append #$output "/bin/" file)))
                     (or (scandir profile-bin
                                  (negate (cut member <> '("." ".."))))
                         '()))
           (unless (file-exists? (string-append profile-bin "/sh"))
             (symlink #$(file-append bash-minimal "/bin/sh")
                      (string-append #$output "/bin/sh")))

           (for-each (lambda (dir)
                       (mkdir-p (string-append #$output "/" dir)))
                     '("proc" "sys" "dev" "home" "tmp" "var/tmp"
                       "etc" ".singularity.d/env" ".singularity.d/libs"))

           ;; Apptainer adds the calling user to these at run time.
           (write-file "etc/passwd" "root:x:0:0:root:/root:/bin/sh\n")
           (write-file "etc/group" "root:x:0:\n")

           (write-file ".singularity.d/runscript"
                       (string-append "#!/bin/sh\n" #$run-script "\n"))
           (chmod (string-append #$output "/.singularity.d/runscript") #o755)

           (write-file ".singularity.d/env/90-environment.sh"
                       (string-append ". " #$profile "/etc/profile\n"
                                      #$(environment-exports environment)))

           ;; Apptainer sets the variables of --env and APPTAINERENV_* right
           ;; after it sources this file, and only then.  As in the one that
           ;; 'apptainer build' writes, /.singularity.d/libs is where --nv
           ;; binds the host's GPU libraries.
           (write-file ".singularity.d/env/99-base.sh"
                       (string-append
                        "export LD_LIBRARY_PATH=\""
                        "${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}"
                        "/.singularity.d/libs\"\n"))

           ;; Env files run before anything else in the container, even
           ;; before Apptainer looks at /bin/sh, which may itself be in a
           ;; layer.
           #$@(if (null? layers)
                  '()
                  (list #~(write-file ".singularity.d/env/00-layers.sh"
                                      (string-append
                                       #$@(map layer-check layers))))))))))

(define-gexp-compiler (apptainer-image-compiler (image <apptainer-image>)
                                                system target)
  (let ((profile (image-profile image)))
    (lower-object
     (store-squashfs (string-append (apptainer-image-name image) ".squashfs")
                     (image-tree image profile)
                     (map references-file (list profile bash-minimal))
                     #:exclude (map apptainer-layer-closure
                                    (apptainer-image-layers image))
                     #:compression (apptainer-image-compression image)
                     #:compression-level
                     (apptainer-image-compression-level image))
     system #:target target)))
