#
# incr test - test ctable "incr" method
#
# $Id$
#

source dumb-data.tcl

#package require Tclx
#cmdtrace on

if {[catch {t incr brock} result] == 1} {
    error "t incr brocks should not have been an error"
} else {
    if {$result != ""} {
        error "t incr brock should have returned an empty result"
    }
}

if {[t incr brock age 1 coolness 10] != [list 36 110]} {
    error "t incr brock age 1 coolness 10 failed"
}

if {[catch {t incr brock foo} result] == 1} {
    if {$result == "key-value list must contain an even number of elements"} {
    } else {
	puts $result
    }
} else {
    error "should have gotten an error"
}

if {[t incr inignot age 2] != 4} {
    error "t incr inignot age 2 failed"
}

if {[catch {t incr frammistan foo 1} result] == 1} {
    if {$result == {bad field "foo": must be name, home, show, dad, alive, gender, age, or coolness}} {
    } else {
	error "got '$result' doing t incr frammistan foo 1"
    }
} else {
    error "should have gotten an error"
}

