" Definition of a stack trace: {{{1
"
" Programmers  commonly use  stack  tracing during  interactive and  post-mortem
" debugging.  End-users may  see a  stack trace  displayed as  part of  an error
" message, which the user can then report to a programmer.
"
" A stack trace allows tracking the sequence  of nested functions called - up to
" the point where the stack trace  is generated.  In a post-mortem scenario this
" extends up to the function where the failure occurred (but was not necessarily
" caused).
"
" For more info: https://en.wikipedia.org/wiki/Stack_trace

" Test {{{1
"
" To test  the `stacktrace#qfl()` function,  install the following  `cd` mapping
" and the `FuncA()`, `FuncB()`, `FuncC()`, `FuncD()` functions:
"
"     nno cd :call FuncA()<cr>
"
"     fu FuncA()
"         call FuncB()
"         call FuncC()
"     endfu
"
"     fu FuncB()
"         abcd
"     endfu
"
"     fu FuncC()
"         call s:FuncD()
"     endfu
"
"     fu s:FuncD()
"         efgh
"     endfu
"
" Then, press `cd`, and execute `:WTF`.

" Interface {{{1
fu stacktrace#main(lvl) abort "{{{2
    " example value for `errors`:{{{
    "
    "     [
    "     \ {'stack': ['FuncB[34]', 'FuncA[12]'],
    "     \  'msg': 'E492: Not an editor command:     abcd'},
    "     \
    "     \ {'stack': ['<SNR>3_FuncD[78]', 'FuncC[56]'],
    "     \  'msg': 'E492: Not an editor command:     efgh'},
    "     ]
    "
    " In this fictitious example, 2 errors occurred in FuncB() and s:FuncD(),
    " and the chains of calls were:
    "
    "     FuncA → FuncB
    "     FuncC → s:FuncD
    "}}}
    let errors = s:get_raw_trace(a:lvl)
    if empty(errors)
        echo '[stacktrace] no stack trace in :messages'
        return
    endif

    let qfl = s:build_qfl(errors)
    if empty(qfl)
        echohl ErrorMsg
        echo '[stacktrace] unable to parse the stack trace'
        echohl NONE
        return
    endif

    call s:populate_qfl(qfl)
endfu
"}}}1
" Core {{{1
fu s:get_raw_trace(max_dist = 3) abort "{{{2
    " for some reason,  `execute()` sometimes produces 1  or several consecutive
    " empty line(s) even though they aren't there in the output of `:messages`
    let msgs = execute('messages')->split('\n\+')

    " a parseable error needs at least 3 lines
    if len(msgs) < 3 | return | endif

    let [i, e, errors] = [len(msgs) - 1, -1, []]
    "    │  │  │{{{
    "    │  │  └ list of errors built in the next loop;
    "    │  │    each error will be a dictionary containing 2 keys,
    "    │  │    whose values will be a stack and a message
    "    │  │
    "    │  └ index of the last message where an error occurred
    "    │
    "    └ index of the message processed in the next loop;
    "      we start from the last one because we're interested in the most recent error(s)
    "}}}

    " iterate over the messages in the log
    while i >= 0

        " We ignore error messages raised from pseudo-files under `/proc/`.{{{
        "
        " Because we can't  visit those files anyway, so populating  a qfl would
        " be useless, and distracting when we  would find out that we can't read
        " the code which raised the errors.
        "
        " That can happen when we turn a Vim script into a shell heredoc.
        "}}}
        if msgs[i] =~# '^Error detected while processing \%(command line\.\.script /proc/\d\+/fd/\d\+\)\@!'
            \ && msgs[i + 1] =~? '^line\s\+\d\+'

            " ... then get the line address  in the innermost function where the
            " error occurred
            let lnum = matchstr(msgs[i + 1], '\d\+')

            " ... and the stack of function calls leading to the error
            let partial_stack = matchstr(msgs[i],
                \ 'Error detected while processing \%(function \|command line\.\.\)\=\zs.*\ze:$')

            " combine `lnum` and `partial_stack` to build a string describing the complete stack
            " Example of value for the `stack` variable:{{{
            "
            "     FuncA[12]..FuncB[34]..FuncC[56]
            "}}}
            let stack = printf('%s[%d]', partial_stack, lnum)
            "                     ├──┘{{{
            "                     └ add the address of the line where the
            "                       innermost error occurred (ex: 56),
            "                       inside square brackets (to follow the
            "                       notation used by Vim for the outer functions)
            "}}}

            " Now that we have the stack as a string, we need to:{{{
            "
            "    1. convert it into a list
            "    2. store it into a dictionary
            "    3. add the associated error message to the dictionary
            "    4. add the dictionary to a list of all errors found so far
            "}}}
            " Why `map(... substitute(...))`?{{{
            "
            " It may be necessary when the error is raised from a script sourced
            " manually:
            "
            "     " write this in /tmp/t.vim
            "     vim9script
            "     def FuncA(n: number)
            "         if n == 123
            "             # some comment
            "             FuncB('string')
            "         endif
            "     enddef
            "     def FuncB(n: number)
            "         echo n
            "     enddef
            "     FuncA(123)
            "
            "     $ vim /tmp/t.vim
            "     :so%
            "
            "     Error detected while processing /tmp/d.vim[11]..function <SNR>185_FuncA:~
            "                                                     ^-------^
            "                                                     noise which must be removed
            "
            " Same  thing for  a  command executed  via  the shell  command-line
            " (also, think about a script turned into a shell heredoc):
            "
            "     Error detected while processing command line..script /proc/32041/fd/11[11]..function <SNR>151_FuncA:~
            "                                                                                 ^-------^
            "
            " When an error  is raised from a function which  was not called via
            " the command-line nor a  sourced script (mapping, command, autocmd,
            " ...), we don't need to remove anything:
            "
            "     Error detected while processing function FuncA[2]..FuncC[1]..<SNR>151_FuncD:~
            "                                     ^-------^
            "                                     no need to remove this; we didn't extract it
            "
            " ---
            "
            " For a similar reason, we may need to remove the word `script`:
            "
            "     Error detected while processing FileType Autocommands for "*"
            "     ..Syntax Autocommands for "*"
            "     ..function <SNR>20_SynSet[25]
            "     ..script /home/user/.vim/plugged/vim-vim/after/syntax/vim.vim:
            "       ^-----^
            "       noise
            "
            " Note that  in this example,  the message is artificially  split on
            " multiple  lines,  to improve  the  readability.   In a  real  case
            " scenarion, everything is given in a single message line.
            "}}}
            " Example of value for the `stack` key: {{{
            "
            "     ['FuncA[12]', 'FuncB[34]', 'FuncC[56]']
            "
            " Example of value for the `msg` key:
            "
            "     E492: Not an editor command:     abcd
            "
            " Example of values for the messages:
            "
            "     msgs[i] = 'Error detected while processing ...:'
            "     msgs[i + 1] = 'line  42:'
            "     msgs[i + 2] = 'E123: ...'
            ""}}}
            call add(errors, {
                \ 'stack': split(stack, '\.\.')
                \     ->map({_, v -> substitute(v, '^\C\%(function\|script\) ', '', '')})
                \     ->reverse(),
                \ 'msg': msgs[i + 2],
                \ })

            " remember the index of the message in the log where an error occurred
            let e = i
        endif

        " in the next iteration of the loop, process previous message
        let i -= 1

        if e != -1 && e - i > a:max_dist
        "  ├─────┘    ├────────────────┘{{{
        "  │          └ there're more than `a:max_dist` lines between the next
        "  │            message in the log, and the last one which contained
        "  │            "Error detected while processing function"
        "  │
        "  └ there has been at least an error
        "}}}
            " get out of the loop because the distance is too high
            break
            " If we're only interested in the last error, then why 3? {{{
            "
            "     i - e > 3
            "
            " Why not 1? :
            "
            "     i - e > 1
            "
            " Because an error takes 3 lines in the log.  Example:
            "
            "     Error detected while processing function foo
            "     line    12:
            "     E492: Not an editor command:     bar
            "
            " Note that if we have several consecutive errors, the loop
            " should still process them all, because there will only be
            " 2 lines between 2 of them.  Example:
            "
            "     Error detected while processing function foo   <+
            "     line    12:                                     │ a:max_dist
            "     E492: Not an editor command:     bar            │
            "     Error detected while processing function baz   <+
            "     line    34:
            "     E492: Not an editor command:     qux
            ""}}}
        endif
    endwhile

    " reverse the errros, because I like reading them in their chronological order
    return reverse(errors)
endfu

fu s:build_qfl(errors) abort "{{{2
    let qfl = []

    " iterate over the errors (there could be only one)
    for err in a:errors
        " we use `i` to index the position of a function call in the stack trace
        let i = 0

        " add the error message to the qfl
        call add(qfl, {'text': err.msg, 'lnum': 0, 'bufnr': 0})

        " Now, we need to add to the qfl, the function calls which lead to the error.{{{
        "
        " And for each of them, we need to find out where it was made:
        "
        "    - which file
        "    - which line of the file (!= line of the function)
        "
        " example value for `err.stack`:
        "
        "     ['FuncB[34]', 'FuncA[12]']
        "
        " example value for `call`:
        "
        "     'FuncB[34]'
        "}}}
        for call in err.stack
            " example value: `FuncB`
            let name = matchstr(call, '.\{-}\ze\[\d\+\]$')

            " if we don't have a function name, process next function call in the stack
            if empty(name)
                continue
            endif

            " example value: `34`
            let lnum = matchstr(call, '\[\zs\d\+\ze\]$')->str2nr()

            " if the name of a function contains a slash, or a dot, it's
            " not a function, it's a file
            "
            " it happens when the error occurred in a sourced file, like
            " a ftplugin (put an invalid command in one of them to reproduce)
            if name =~# '[/.]'
                call add(qfl, {'text': '', 'filename': name, 'lnum': lnum})
                " there's no chain of calls, the only error comes from this file
                continue
            else
                " example value:{{{
                "      ['   function FuncB()',
                "     \ '    Last set from ~/.vim/vimrc',
                "     \ ...,
                "     \ '34    abcd',
                "     \ ...,
                "     \ '   endfunction']
                "}}}
                let def = execute('verb function ' .. name, 'silent!')->split('\n')
            endif

            " if  the function  definition doesn't  have at  least 2  lines, the
            " information we need isn't there, so don't bother creating an entry
            " in the qfl for it; instead process next function call in the stack
            if len(def) < 2
                continue
            endif

            " expand the full path of the source file from which the function call was made
            let src = matchstr(def[1], 'Last set from \zs.\+\ze line \d\+')->fnamemodify(':p')
            " if it's not readable,  we won't be able to visit  it from the qfl,
            " so, again, process next function call in the stack
            if !filereadable(src)
                continue
            endif
            let lnum += matchstr(def[1], 'Last set from .\+ line \zs\d\+')

            " Finally, we can add an entry for the function call.{{{
            "
            " We have its filename with `src`.
            " We have its line address with `lnum`.
            " And we can generate a simple text with:
            "
            "     printf('%s. %s', i, call),
            "             │   │
            "             │   └ function call; ex: 'FuncA[12]'
            "             └ index of the function call in the stack
            "               the lower, the deeper
            "
            " The final text could be sth like:
            "
            "     '0. Func[12]'
            "}}}
            call add(qfl, {
                \   'text': printf('%s. %s', i, call),
                \   'filename': src,
                \   'lnum': lnum,
                \ })

            " increment `i` to update the index of the next function call in the stack
            let i += 1
        endfor
    endfor

    return qfl
endfu

fu s:populate_qfl(qfl) abort "{{{2
    call setqflist([], ' ', {'items': a:qfl, 'title': 'WTF'})
    " no need to make Vim open the qf window if it's already open
    if &ft isnot# 'qf'
        do <nomodeline> QuickFixCmdPost copen
    endif
    sil! call qf#set_matches('stacktrace:populate_qfl', 'Conceal', 'double_bar')
    sil! call qf#create_matches()
endfu
