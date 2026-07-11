" Tarang2_dp1 — transparent in-memory decrypt/encrypt for *.enc source files
"
" Plaintext is never written to any file. Reading a *.enc file decrypts it
" straight into the Vim buffer via an openssl pipe; saving pipes the buffer
" back through openssl and overwrites the .enc file. Swapfile/backup/undofile
" are disabled for these buffers so Vim itself can't spill plaintext to disk.
"
" Matches *.enc generically (not just *.v.enc) — lab content spans Verilog,
" SystemVerilog, C, Perl, assembly, headers, and sim scripts, not just .v.
" *.swp.enc/*.swo.enc are skipped — those are stale encrypted Vim swapfiles,
" not source to decrypt and edit.
"
" The key is read from ~/.rbk_state (written once at container startup by
" tarang2-dp1-key-init.sh) rather than an environment variable, so it doesn't
" show up in `env` or `docker inspect`.

if exists('g:loaded_tarang2-dp1_crypt')
  finish
endif
let g:loaded_tarang2-dp1_crypt = 1

set viminfo=

" Root paths — read from env vars set by the container (with fallbacks)
let s:lab_root   = !empty($WORK)  ? expand('$WORK')  : expand('$HOME') . '/lab'
let s:build_root = !empty($BUILD) ? expand('$BUILD') : s:lab_root . '/build'

" Extensions where a leading "// stamp" line is valid syntax. Other types
" (asm, pl, ini, do, txt, list, …) skip the visible decoy header — the
" invisible trailing-space watermark (works on any text) still applies.
let s:slashslash_comment_exts = ['v', 'sv', 'svh', 'vh', 'c', 'h']

function! s:ReadKey()
  let l:path = expand('~/.rbk_state')
  if !filereadable(l:path)
    return ''
  endif
  let l:lines = readfile(l:path)
  return len(l:lines) > 0 ? l:lines[0] : ''
endfunction

" Strip the trailing .enc to get the real filename, e.g. counter.v.enc -> counter.v
function! s:InnerName()
  return fnamemodify(expand('%'), ':r')
endfunction

function! s:IsSwapArtifact()
  return s:InnerName() =~# '\.sw[op]$'
endfunction

function! s:HardenBuffer()
  setlocal noswapfile
  setlocal nobackup
  setlocal nowritebackup
  setlocal noundofile
  setlocal bufhidden=wipe
endfunction

function! s:Decrypt()
  call s:HardenBuffer()
  if s:IsSwapArtifact()
    return
  endif

  let l:key = s:ReadKey()
  if empty(l:key)
    echohl ErrorMsg | echom 'Tarang2_dp1: could not read decryption key (~/.rbk_state missing)' | echohl None
    return
  endif

  " BufReadCmd means Vim never loaded this file itself — the buffer starts
  " as a single empty line, not the real ciphertext. Read the actual file
  " explicitly via -in; piping the (empty) buffer through openssl as stdin
  " (the old `%!openssl ...` approach) decrypted nothing.
  let l:enc_path = expand('%:p')
  silent execute '0r !openssl enc -d -aes-256-cbc -pbkdf2 -k ' . shellescape(l:key) .
        \ ' -in ' . shellescape(l:enc_path)
  if v:shell_error != 0
    echohl ErrorMsg | echom 'Tarang2_dp1: decrypt failed for ' . expand('%') | echohl None
    silent %delete _
    return
  endif
  " :0r inserts above the buffer's original single empty line, pushing it
  " to the bottom — remove that leftover line (blackhole register, doesn't
  " touch the unnamed/clipboard register).
  silent $delete _

  let l:student = empty($GITHUB_USER) ? 'unknown' : $GITHUB_USER
  silent execute '%!python3 /usr/local/bin/watermark.py encode ' . shellescape(l:student)

  let l:ext = fnamemodify(s:InnerName(), ':e')
  if index(s:slashslash_comment_exts, l:ext) >= 0
    call append(0, '// [Tarang2_dp1] Student: @' . l:student . ' | ' . strftime('%Y-%m-%d'))
  endif

  " Detect filetype from the real filename (strip .enc) without reading it.
  silent! execute 'doautocmd filetypedetect BufRead ' . fnameescape(s:InnerName())
  set nomodified
endfunction

function! s:Encrypt()
  if s:IsSwapArtifact()
    return
  endif

  let l:key = s:ReadKey()
  if empty(l:key)
    echohl ErrorMsg | echom 'Tarang2_dp1: could not read encryption key — NOT SAVED' | echohl None
    return
  endif

  let l:lines = getline(1, '$')
  if len(l:lines) > 0 && l:lines[0] =~# '^// \[Tarang2_dp1\] Student:'
    let l:lines = l:lines[1:]
  endif

  let l:enc_path = expand('%:p')
  let l:tmp = tempname()
  let l:tmp_wm = l:tmp . '.wm'
  let l:tmp_enc = l:tmp . '.enc'
  call writefile(l:lines, l:tmp, 'b')

  " Re-apply the invisible watermark at save time too (idempotent — encoding
  " the same username twice yields the same bits), so it's guaranteed
  " present even for a file that's never been through Decrypt(), e.g. a
  " brand-new design saved for the first time.
  let l:student = empty($GITHUB_USER) ? 'unknown' : $GITHUB_USER
  call system('python3 /usr/local/bin/watermark.py encode ' . shellescape(l:student) .
        \ ' < ' . shellescape(l:tmp) . ' > ' . shellescape(l:tmp_wm))
  let l:src_for_enc = v:shell_error == 0 ? l:tmp_wm : l:tmp

  call system('openssl enc -aes-256-cbc -pbkdf2 -salt -k ' . shellescape(l:key) .
        \ ' -in ' . shellescape(l:src_for_enc) . ' -out ' . shellescape(l:tmp_enc))
  let l:ok = v:shell_error == 0

  " If a persistent decrypted copy exists in build/ for this file (put
  " there by tarang2-dp1-decrypt-all.sh at startup), sync it now so that
  " compile.pl/regress.pl see the latest edit, not the stale startup copy.
  " Uses the watermarked plaintext (no visible header) — same format that
  " tarang2-dp1-decrypt-all.sh produces — so the build/ copy stays consistent.
  if l:ok
    let l:inner = fnamemodify(l:enc_path, ':r')
    if l:inner =~# '^' . escape(s:lab_root, '/\') . '/'
      let l:rel = l:inner[len(s:lab_root) + 1:]
      let l:build_copy = s:build_root . '/' . l:rel
      if isdirectory(fnamemodify(l:build_copy, ':h'))
        " Build copy is left writable — direct editing in build/ is permitted
        call system('chmod u+w ' . shellescape(l:build_copy) . ' 2>/dev/null || true')
        call writefile(readfile(l:src_for_enc, 'b'), l:build_copy, 'b')
      endif
    endif
  endif

  call delete(l:tmp)
  call delete(l:tmp_wm)
  if !l:ok
    call delete(l:tmp_enc)
    echohl ErrorMsg | echom 'Tarang2_dp1: encrypt failed — NOT SAVED' | echohl None
    return
  endif

  " Unlock the destination .enc file before overwriting (it may be read-only)
  call system('chmod u+w ' . shellescape(l:enc_path) . ' 2>/dev/null || true')
  call mkdir(fnamemodify(l:enc_path, ':h'), 'p')
  call rename(l:tmp_enc, l:enc_path)
  call system('chmod a-w ' . shellescape(l:enc_path) . ' 2>/dev/null || true')
  set nomodified
endfunction

" ── Guard against bare (non-.enc) source files under WORK or BUILD ───────────
"
" If a student opens "new_tests.v" instead of "new_tests.v.enc" — an easy
" typo, not a deliberate bypass — none of the above applies: Vim's default
" swapfile is created, and :w would write real plaintext straight to disk,
" completely outside the encryption scheme. This mirrors the same allowlist
" tarang2-dp1-files/.gitignore already enforces at the git layer (only
" Makefile/.gitignore/.gitattributes/README.md and *.enc are real plaintext),
" but live in the editor instead of just at commit time.
" build/ is exempt for reads — that is the tmpfs build-scratch area where
" transient plaintext is expected to be read. Writes from build/ are
" redirected back to the .enc source.

let s:plain_allowlist = ['Makefile', '.gitignore', '.gitattributes', 'README.md']

function! s:UnderLab(path)
  return a:path =~# '^' . escape(s:lab_root, '/\') . '/'
endfunction

function! s:UnderBuild(path)
  return a:path =~# '^' . escape(s:build_root, '/\') . '\(/\|$\)'
endfunction

function! s:IsAllowedPlain(path)
  return index(s:plain_allowlist, fnamemodify(a:path, ':t')) >= 0
endfunction

function! s:PassthroughRead()
  if filereadable(expand('%:p'))
    silent call setline(1, readfile(expand('%:p'), 'b'))
  endif
  silent! execute 'doautocmd filetypedetect BufRead ' . fnameescape(expand('%:p'))
  set nomodified
endfunction

function! s:PassthroughWrite()
  call mkdir(fnamemodify(expand('%:p'), ':h'), 'p')
  call writefile(getline(1, '$'), expand('%:p'), 'b')
  set nomodified
endfunction

function! s:GuardedRead()
  let l:path = expand('%:p')
  " .enc files are handled by the Tarang2_dp1Crypt group above; anything
  " outside WORK/BUILD entirely is none of this guard's business either.
  if l:path =~# '\.enc$' || (!s:UnderLab(l:path) && !s:UnderBuild(l:path))
    return
  endif
  call s:HardenBuffer()
  call s:PassthroughRead()
  if !s:UnderBuild(l:path) && !s:IsAllowedPlain(l:path)
    echohl WarningMsg
    echom 'Tarang2_dp1: "' . fnamemodify(l:path, ':t') . '" is plaintext under projects — save as .enc instead.'
    echohl None
  endif
endfunction

function! s:GuardedWrite()
  let l:path = expand('%:p')
  if l:path =~# '\.enc$' || (!s:UnderLab(l:path) && !s:UnderBuild(l:path))
    return
  endif
  if s:IsAllowedPlain(l:path)
    call s:PassthroughWrite()
    return
  endif
  if s:UnderBuild(l:path)
    " Editing a plaintext file directly from build/ — find the .enc
    " counterpart in WORK and encrypt to it, so edits persist across
    " container restarts. Saving from build/ should be equivalent to
    " editing the .enc source directly — no silent lost-work trap.
    let l:rel = l:path[len(s:build_root . '/'):]
    let l:enc_path = s:lab_root . '/' . l:rel . '.enc'
    let l:key = s:ReadKey()
    if empty(l:key)
      echohl ErrorMsg | echom 'Tarang2_dp1: no key — cannot encrypt to .enc' | echohl None
      return
    endif
    let l:tmp = tempname()
    let l:tmp_wm = l:tmp . '.wm'
    let l:tmp_enc = l:tmp . '.enc'
    call writefile(getline(1, '$'), l:tmp, 'b')
    let l:student = empty($GITHUB_USER) ? 'unknown' : $GITHUB_USER
    call system('python3 /usr/local/bin/watermark.py encode ' . shellescape(l:student) .
          \ ' < ' . shellescape(l:tmp) . ' > ' . shellescape(l:tmp_wm))
    let l:src = v:shell_error == 0 ? l:tmp_wm : l:tmp
    call system('openssl enc -aes-256-cbc -pbkdf2 -salt -k ' . shellescape(l:key) .
          \ ' -in ' . shellescape(l:src) . ' -out ' . shellescape(l:tmp_enc))
    let l:ok = v:shell_error == 0
    call delete(l:tmp)
    call delete(l:tmp_wm)
    if !l:ok
      call delete(l:tmp_enc)
      echohl ErrorMsg | echom 'Tarang2_dp1: encrypt failed — .enc not updated' | echohl None
      return
    endif
    " Unlock enc destination before overwriting
    call system('chmod u+w ' . shellescape(l:enc_path) . ' 2>/dev/null || true')
    call mkdir(fnamemodify(l:enc_path, ':h'), 'p')
    call rename(l:tmp_enc, l:enc_path)
    call system('chmod a-w ' . shellescape(l:enc_path) . ' 2>/dev/null || true')
    " Build copy is left writable — direct editing in build/ is permitted
    call system('chmod u+w ' . shellescape(l:path) . ' 2>/dev/null || true')
    call s:PassthroughWrite()
    echom 'Tarang2_dp1: saved ' . fnamemodify(l:path, ':t') . ' and updated ' . fnamemodify(l:enc_path, ':t')
    return
  endif
  echohl ErrorMsg
  echom 'Tarang2_dp1: refusing to save plaintext "' . fnamemodify(l:path, ':t') . '" under projects.'
  echom 'Tarang2_dp1: save as "' . fnamemodify(l:path, ':t') . '.enc" instead — gvim will encrypt it automatically.'
  echohl None
endfunction

augroup Tarang2_dp1Crypt
  autocmd!
  autocmd BufReadPre,BufNewFile *.enc call s:HardenBuffer()
  autocmd BufReadCmd  *.enc call s:Decrypt()
  autocmd BufWriteCmd *.enc call s:Encrypt()
augroup END

" Watch both WORK (.build.enc) and BUILD (build) directories
let s:lab_pattern   = s:lab_root   . '/**'
let s:build_pattern = s:build_root . '/**'

augroup Tarang2_dp1PlainGuard
  autocmd!
augroup END
execute 'autocmd Tarang2_dp1PlainGuard BufReadPre,BufNewFile ' . s:lab_pattern   . ' call s:HardenBuffer()'
execute 'autocmd Tarang2_dp1PlainGuard BufReadCmd  '           . s:lab_pattern   . ' call s:GuardedRead()'
execute 'autocmd Tarang2_dp1PlainGuard BufWriteCmd '           . s:lab_pattern   . ' call s:GuardedWrite()'
execute 'autocmd Tarang2_dp1PlainGuard BufReadPre,BufNewFile ' . s:build_pattern . ' call s:HardenBuffer()'
execute 'autocmd Tarang2_dp1PlainGuard BufReadCmd  '           . s:build_pattern . ' call s:GuardedRead()'
execute 'autocmd Tarang2_dp1PlainGuard BufWriteCmd '           . s:build_pattern . ' call s:GuardedWrite()'
