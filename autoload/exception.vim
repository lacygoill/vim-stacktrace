fu! exception#trace() abort
    " get the log messages
    let lines = reverse(split(execute('sil messages'), "\n"))
"               │
"               └─ reverse the order because we're interested in the most
"                  recent error

    " if we've just started Vim, there'll be only 2 lines in the log
    " in this case don't do anything, because there's no error
    if len(lines) < 3
        return
    endif

    let [ i, e, errors ] = [ 0, 0, [] ]
"         │  │  │
"         │  │  └─ list of errors built in the next while loop
"         │  └─ index of the last line where an error occurred
"         └─ index of the line of the log currently processed in the next
"            while loop

    " iterate over the lines in the log
    while i < len(lines)

        " if a line begins with “Error detected while processing function“
        " and the previous one with “line 123“ (123 being a random number)
        if i > 1 && lines[i] =~# '^Error detected while processing function '
                    \ && lines[i-1] =~? '\v^line\s+\d+'

            " get the line where the error occurred
            let lnum  = matchstr(lines[i-1], '\d\+')

"               ┌─ typical value:    <SNR>3_broken_func[123]
"               │
            let stack = printf('%s[%d]', lines[i][41:-2], lnum)
            let g:stack = deepcopy(stack)
"                                        │
"                                        └─ name of the function
"                                           the name begins after the 41th character,
"                                           and `-2` gets rid of a colon at the end of the line
            call add(errors, {
                             \  'stack': reverse(split(stack, '\.\.')),
                             \  'msg':   lines[i-2],
                             \ })
            let e = i
        endif

        " increment `i` to process next line in the log, in the next
        " iteration of the while loop
        let i += 1

"          ┌─ there has been at least an error
"          │
        if e && i - e > 3
"               └───────┤
"                       └ there're more than 3 lines between the current line of the
"                         log, and the last one which contained a “Error detected
"                         while processing function“ message

            " get out of the while loop because we're only interested in the
            " last error
            break
        endif
    endwhile

    " if there aren't any error, return
    if empty(errors)
        return
    endif

    let errlist = []

    for err in errors
        let nw = len(len(err.stack))
        let i  = 0
        call add(errlist, {
                          \   'text':  err.msg,
                          \   'lnum':  0,
                          \   'bufnr': 0,
                          \   'type':  'E',
                          \ })

        for t in err.stack
            let func = matchstr(t, '\v.{-}\ze\[\d+\]$')
            let lnum = str2nr(matchstr(t, '\v\[\zs\d+\ze\]$'))

            let verb = split(execute('sil! verbose function '.func), "\n")
            if len(verb) < 2
                continue
            endif

            let src = fnamemodify(matchstr(verb[1], '\vLast set from \zs.+'), ':p')
            if !filereadable(src)
                continue
            endif

            let pat = '\v\C^\s*fu%[nction]!?\s+'
            if func =~# '^<SNR>'
                let pat .= '%(\<%(sid|SID)\>|s:)'
                let func = matchstr(func, '\v\<SNR\>\d+_\zs.+')
            endif
            let pat .= func.'>'

            for line in readfile(src)
                let lnum += 1
                if line =~# pat
                    break
                endif
            endfor

            if !empty(src) && !empty(func)
                let fname = fnamemodify(src, ':.')
                call add(errlist, {
                                  \   'text':     printf('%*s. %s', nw, '#'.i, t),
                                  \   'filename': fname,
                                  \   'lnum':     lnum,
                                  \   'type':     'I',
                                  \ })
            endif

            let i += 1
        endfor
    endfor

    if !empty(errlist)
        call setqflist(errlist, 'r')
        copen
    endif
endfu
