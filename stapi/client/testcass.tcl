#!/bin/sh

set d [exec pwd]
if [file exists $d/pkgIndex.tcl] {
  puts stderr "auto path is $d"
  lappend auto_path $d
}
set d [file dirname $d]
if [file exists $d/pkgIndex.tcl] {
  puts stderr "auto path is $d"
  lappend auto_path $d
}

package require st_client_cassandra

if ![info exists env(CASSTCL_CONTACT_POINTS)] {
  error "Please set environment variables CASSTCL_USERNAME, CASSTCL_CONTACT_POINTS, CASSTCL_PASSWORD"
}

set c [::stapi::connect cass:///test.school/]

$c search -compare {{> age 20}} -array row -code {
  puts [array get row]
}

