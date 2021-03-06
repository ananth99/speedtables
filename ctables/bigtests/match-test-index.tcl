

source nametest-extension.tcl

source cputime.tcl

puts "loading data"
puts [cputime {source name-data.tcl}]

puts "creating index"
puts [cputime {n index create name}]
puts "done"

proc test1 {} {
    puts "matching *lehenbauer*"

    n search+ -compare {{match name "*lehenbauer*"}} -write_tabsep stdout
}

puts [cputime test1]

proc test2 {} {
    puts "matching *Sylvester*Bakerville*"

    n search+ -compare {{match name "*Sylvester*Bakerville*"}} -write_tabsep stdout
}

puts [cputime test2]

proc test3 {} {
    puts "matching *lehenbauer* count only"

    puts [n search+ -compare {{match name "*lehenbauer*"}} -countOnly 1]
}

puts [cputime test3]

proc test4 {} {
    puts "\nmatching *Disney* count only"
    puts [n search+ -compare {{match name "*Disney*"}} -countOnly 1]

}

puts [cputime test4]

proc test5 {} {
    puts "\nmatching *Disney* -write_tabsep /dev/null"
    set ofp [open /dev/null w]
    puts [n search+ -compare {{match name "*Disney*"}} -write_tabsep $ofp]
    close $ofp
}

puts [cputime test5]

proc test6 {} {
    puts "\nmatching *Wozniak* with fairly empty -code loop"
    puts [n search+ -compare {{match name "*Wozniak*"}} -key key -array_get_with_nulls data -code {}]

}

puts [cputime test6]

proc test7 {} {
    puts "\nmatching Bernadine* with fairly empty -code loop"
    puts [n search+ -compare {{match name "Bernadine*"}} -key key -array_get_with_nulls data -code {}]

}

puts [cputime test7]

proc test8 {} {
    puts "\nmatching *Bernadine* with fairly empty -code loop"
    puts [n search+ -compare {{match name "*Bernadine*"}} -key key -array_get_with_nulls data -code {}]

}

puts [cputime test8]

proc test9 {} {
    puts "\nmatching *Bernadine*Rottinghous with fairly empty -code loop"
    puts [n search+ -compare {{match name "*Bernadine*Rottinghous*"}} -key key -array_get_with_nulls data -code {}]

}

puts [cputime test9]

proc test10 {} {
    puts "\n= Tatiana Lehenbauer with fairly empty -code loop"
    puts [n search+ -compare {{= name "Tatiana Lehenbauer"}} -key key -array_get_with_nulls data -code {}]

}

puts [cputime test10]


