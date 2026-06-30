" ChipCraft Lab — transparent in-memory decrypt/encrypt for *.enc source files
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
" The key is read from ~/.chipcraft_key (written once at container startup by
" chipcraft-key-init.sh) rather than an environment variable, so it doesn't
" show up in `env` or `docker inspect`.

if exists('g:loaded_chipcraft_crypt')
  finish
endif
let g:loaded_chipcraft_crypt = 1

set viminfo=

" Extensions where a leading "// stamp" line is valid syntax. Other types
" (asm, pl, ini, do, txt, list, …) skip the visible decoy header — the
" invisible trailing-space watermark (works on any text) still applies.
let s:slashslash_comment_exts = ['v', 'sv', 'svh', 'vh', 'c', 'h']

function! s:ReadKey()
  let l:path = expand('~/.chipcraft_key')
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
    echohl ErrorMsg | echom 'ChipCraft: could not read decryption key (~/.chipcraft_key missing)' | echohl None
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
    echohl ErrorMsg | echom 'ChipCraft: decrypt failed for ' . expand('%') | echohl None
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
    call append(0, '// [ChipCraft] Student: @' . l:student . ' | ' . strftime('%Y-%m-%d'))
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
    echohl ErrorMsg | echom 'ChipCraft: could not read encryption key — NOT SAVED' | echohl None
    return
  endif

  let l:lines = getline(1, '$')
  if len(l:lines) > 0 && l:lines[0] =~# '^// \[ChipCraft\] Student:'
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

  call delete(l:tmp)
  call delete(l:tmp_wm)
  if !l:ok
    call delete(l:tmp_enc)
    echohl ErrorMsg | echom 'ChipCraft: encrypt failed — NOT SAVED' | echohl None
    return
  endif

  call mkdir(fnamemodify(l:enc_path, ':h'), 'p')
  call rename(l:tmp_enc, l:enc_path)
  set nomodified
endfunction

" ── Guard against bare (non-.enc) source files under ~/lab ──────────────────
"
" If a student opens "new_tests.v" instead of "new_tests.v.enc" — an easy
" typo, not a deliberate bypass — none of the above applies: Vim's default
" swapfile is created, and :w would write real plaintext straight to disk,
" completely outside the encryption scheme. This mirrors the same allowlist
" chipcraft-lab-files/.gitignore already enforces at the git layer (only
" Makefile/.gitignore/.gitattributes/README.md and *.enc are real plaintext),
" but live in
" the editor instead of just at commit time. ~/lab/build/ is exempt — that's
" the tmpfs build-scratch area where transient plaintext is expected.

let s:lab_root = expand('$HOME') . '/lab'
let s:plain_allowlist = ['Makefile', '.gitignore', '.gitattributes', 'README.md']

function! s:UnderLab(path)
  return a:path =~# '^' . escape(s:lab_root, '/\') . '/'
endfunction

function! s:UnderBuild(path)
  return a:path =~# '^' . escape(s:lab_root, '/\') . '/build\(/\|$\)'
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
  " .enc files are handled by the ChipCraftCrypt group above; anything
  " outside ~/lab entirely is none of this guard's business either.
  if l:path =~# '\.enc$' || !s:UnderLab(l:path)
    return
  endif
  call s:HardenBuffer()
  call s:PassthroughRead()
  if !s:UnderBuild(l:path) && !s:IsAllowedPlain(l:path)
    echohl WarningMsg
    echom 'ChipCraft: "' . fnamemodify(l:path, ':t') . '" is plaintext under ~/lab — save as .enc instead.'
    echohl None
  endif
endfunction

function! s:GuardedWrite()
  let l:path = expand('%:p')
  if l:path =~# '\.enc$' || !s:UnderLab(l:path)
    return
  endif
  if s:UnderBuild(l:path) || s:IsAllowedPlain(l:path)
    call s:PassthroughWrite()
    return
  endif
  echohl ErrorMsg
  echom 'ChipCraft: refusing to save plaintext "' . fnamemodify(l:path, ':t') . '" under ~/lab.'
  echom 'ChipCraft: save as "' . fnamemodify(l:path, ':t') . '.enc" instead — gvim will encrypt it automatically.'
  echohl None
endfunction

augroup ChipCraftCrypt
  autocmd!
  autocmd BufReadPre,BufNewFile *.enc call s:HardenBuffer()
  autocmd BufReadCmd  *.enc call s:Decrypt()
  autocmd BufWriteCmd *.enc call s:Encrypt()
augroup END

let s:lab_pattern = s:lab_root . '/**'

augroup ChipCraftPlainGuard
  autocmd!
augroup END
execute 'autocmd ChipCraftPlainGuard BufReadPre,BufNewFile ' . s:lab_pattern . ' call s:HardenBuffer()'
execute 'autocmd ChipCraftPlainGuard BufReadCmd  ' . s:lab_pattern . ' call s:GuardedRead()'
execute 'autocmd ChipCraftPlainGuard BufWriteCmd ' . s:lab_pattern . ' call s:GuardedWrite()'
