#
# STAPI Cassandra Client
#
# This stuff adds cass:// as a stapi URI and provides a way to look at
# Cassandra tables as if they are ctables
#

package require st_client
package require st_client_uri

namespace eval ::stapi {
  variable cassconn

  #
  # set_cass_conn connect-info
  #
  # connection info is either a list of name value pairs or multiple name-value pairs. Missing
  # values will be provided from the environment.
  #
  # -user username	($CASSTCL_USERNAME)
  # -host hostname	($CASSTCL_CONTACT_POINTS)
  # -pass password	($CASSTCL_PASSWORD)
  #
  proc connect_cass {args} {
    variable cassconn
    global env

    if {[llength $args] == 1} {
      set args [lindex $args 0]
    }

    for {opt val} $args {
      regexp {^-(.*)} $opt _ opt
      switch -- $opt {
        contact_points {set host $val}
	host {set host $val}
        user {set user $val}
        pass {set pass $val}
      }
    }
    if {![info exists host]} {
      if [info exists env(CASSTCL_CONTACT_POINTS}] {
	set host $env(CASSTCL_CONTACT_POINTS)
      } else {
	error "No host provided for cassandra connection"
      }
    }
    if {![info exists user]} {
      if [info exists env(CASSTCL_USERNAME)] {
	set user $env(CASSTCL_USERNAME)
      } else {
	error "No user-name provided for cassandra connection"
      }
    }
    if {![info exists pass]} {
      if [info exists env(CASSTCL_PASSWORD)] {
	set user $env(CASSTCL_PASSWORD)
      } else {
	error "No password provided for cassandra connection"
      }
    }

    set cassconn [::casstcl::connect -host $host -user $user -password $pass]
  }

  proc cass {
    variable cassconn

    if {![info exists casscon]} {
      # Hope the environment variables are all there!
      connect_cass
    }

    return $cassconn
  }
   
  #
  # make_cass_uri - given a table name and some optional arguments like
  #  host, user, pass, db, keys, and key, construct a cassandra URI that
  #  looks like cass://...
  #
  proc make_cass_uri {table args} {
    while {[llength $args]} {
      set arg [lindex $args 0]
      set args [lrange $args 1 end]

      if {![regexp {^-(.*)} $arg _ opt]} {
	lappend cols [uri_esc $arg /?]
      } else {
	set val [lindex $args 0]
	set args [lrange $args 1 end]

        switch -- $opt {
	  cols {
	    foreach col $val {
	      lappend cols [uri_esc $col /?]
	    }
	  }

	  # Cassandra contact points can have multiple values. host is an alias for contact point
	  host {
	      lappend contact_points [uri_esc $val @/:]
	  }

	  contact_point {
	      lappend contact_points [uri_esc $val @/:]
	  }

	  user {
	      set user [uri_esc $val @/:]
	  }

	  pass {
	      set pass [uri_esc $val @/:]
	  }

	  port {
	      set port [uri_esc $val @/:]
	  }

	  keys {
	      lappend params [uri_esc _keys=[join $val :] &]
	  }

	  key {
	      lappend params [uri_esc _key=$val &]
	  }

	  -* {
	    regexp {^-(.*)} $opt _ opt
	    lappend params [uri_esc $opt &=]=[uri_esc $val &]
	  }

	  * {
	    lappend params [uri_esc $opt &=]=[uri_esc $val &]
	  }
	}
      }
    }

    set uri cass://
    if {[info exists user]} {
      if {[info exists pass]} {
	append user : $pass
      }

      append uri $user @
    }

    if {[info exists contact_points]} {
      append uri [join $contact_points ","] :
    }

    if {[info exists port]} {
      append uri $port
    }

    append uri / [uri_esc $table /?]
    if {[info exists cols]} {
      append uri / [join $cols /]
    }

    if {[info exists params]} {
      append uri ? [join $params &]
    }
    return $uri
  }

  variable casstable_seq 0

  #
  # cass_get_columns table_name ?keyspace_name?
  #
  # Returns a list of triples {{column_name kind type} ...}
  #
  # Kind is "regular", "clustering", or "partition_key"
  #
  # Type is CQL type
  #
  proc cass_get_columns {table_name {keyspace_name ""}} {
    if ![string length $keyspace_name] {
      set l [split $table_name "."]
      if {[llength $l] != 2} {
	error "Keyspace not provided for $table_name"
      }
      set keyspace_name [lindex $l 0]
      set table_name [lindex $l 1]
    }
    set query "SELECT column_name, kind, type
                 FROM system_schema.columns
                 WHERE keyspace_name = '$keyspace_name' and table_name = '$table_name';"

    set result {}
    [cass] select $query row {
	lappend result [list $row(column_name) $row(kind) $row(type)]
    }

    return $result
  }

  #
  # connect_cassandra - connect to cassandra by cracking a cass:// uri
  #
  proc connect_cassandra {table {address "-"} args} {
    variable casstable_seq

    set params ""
    regexp {^([^?]*)[?](.*)} $table _ table params
    set path ""
    regexp {^/*([^/]*)/(.*)} $table _ table path
    set path [split $path "/"]
    set table [uri_unesc $table]

    foreach param [split $params "&"] {
      if {[regexp {^([^=]*)=(.*)} $param _ name val]} {
	set vars([uri_unesc $name]) [uri_unesc $val]
      } else {
	set vars([uri_unesc $name]) ""
      }
    }

    set raw_fields {}
    set columns [cass_get_columns $table]
    if {![llength $columns]} {
      error "Failed to describe cassandra table $table"
    }

    foreach {name kind type} [cass_get_columns $table] {
      lappend raw_fields $name
      set field2type($name) $type
      switch -- $kind {
	partition_key { set partition_key $name }
	clustering { lappend cluster_keys $name }
      }
    }

    # If there's no partition key, if there's _key set in the vars, we'll believe the user
    # (may rethink this later)
    if {![info exists partition_key]} {
      if [info exists vars(_key)] {
        set partition_key $vars(_key)
        unset vars(_key)
      } else {
	error "Can't happen! Cassandra table has no partition key!"
      }
    }

    if {[llength $path]} {
      set raw_fields {}
      foreach field $path {
	set field [uri_unesc $field]

	if {[regexp {^([^:]*):(.*)} $field _ field type]} {
	  set field2type($field) $type
	}
        lappend raw_fields $field
      }
    }

    foreach field $raw_fields {
      lappend fields $field

      if {[info exists params($field)]} {
        set field2alias($field) $params($field)
	unset params($field)
      }
    }

    set ns ::stapi::casstable[incr casstable_seq]

    namespace eval $ns {
      #
      # ctable - 
      #
      proc ctable {args} {
	set level [expr {[info level] - 1}]
	catch {::stapi::cass_ctable $level [namespace current] {*}$args} catchResult catchOptions
	dict incr catchOptions -level 1
	return -options $catchOptions $catchResult
      }

      # copy the search proc into this namespace
      proc search_to_cass [info args ::stapi::search_to_cass] [info body ::stapi::search_to_cass]
    }

    set ${ns}::table_name $table
    array set ${ns}::aliases [array get field2alias]
    set ${ns}::key $key
    set ${ns}::fields $fields
    array set ${ns}::types [array get field2type]
    set ${ns}::partition_key $partition_key

    if [info exists $cluster_keys] {
      set ${ns}::cluster_keys $cluster_keys
    }

    return ${ns}::ctable
  }
  register cass connect_cassandra

  variable ctable_commands
  array set ctable_commands {
    get				cass_ctable_get
    set				cass_ctable_set
    array_get			cass_ctable_array_get
    array_get_with_nulls	cass_ctable_array_get_with_nulls
    exists			cass_ctable_exists
    delete			cass_ctable_delete
    count			cass_ctable_count
    foreach			cass_ctable_foreach
    type			cass_ctable_type
    import			cass_ctable_unimplemented
    import_postgres_result	cass_ctable_unimplemented
    export			cass_ctable_unimplemented
    fields			cass_ctable_fields
    fieldtype			cass_ctable_fieldtype
    needs_quoting		cass_ctable_needs_quoting
    names			cass_ctable_names
    reset			cass_ctable_unimplemented
    destroy			cass_ctable_destroy
    search			cass_ctable_search
    search+			cass_ctable_search
    statistics			cass_ctable_unimplemented
    write_tabsep		cass_ctable_unimplemented
    read_tabsep			cass_ctable_read_tabsep
    index			cass_ctable_ignore_null
  }
  variable ctable_extended_commands
  array set ctable_extended_commands {
    methods			cass_ctable_methods
    key				cass_ctable_key
    keys			cass_ctable_keys
    makekey			cass_ctable_makekey
    store			cass_ctable_store
  }

  #
  # cass_ctable -
  #
  proc cass_ctable {level ns cmd args} {
    variable ctable_commands
    variable ctable_extended_commands

    if {[info exists ctable_commands($cmd)]} {
      set proc $ctable_commands($cmd)
    } elseif {[info exists ctable_extended_commands($cmd)]} {
      set proc $ctable_extended_commands($cmd)
    } else {
      set proc sql_ctable_unimplemented
    }

    catch {$proc $level $ns $cmd {*}$args} catchResult catchOptions
    dict incr catchOptions -level 1
    return -options $catchOptions $catchResult
  }

  #
  # cass_ctable_methods -
  #
  proc cass_ctable_methods {level ns cmd args} {
    variable ctable_commands
    variable ctable_extended_commands

    return [
      lsort [
        concat [array names ctable_commands] \
	       [array names ctable_extended_commands]
      ]
    ]
  }

  #
  # cass_ctable_key - 
  #
  proc cass_ctable_key {level ns cmd args} {
    if [info exists ${ns}::cluster_keys] {
      return _key
    }
    return [set ${ns}::partition_key]
  }

  #
  # sql_ctable_keys -
  #
  proc cass_ctable_keys {level ns cmd args} {
    set keys {}
    lappend keys [set ${ns}::partition_key]
    if [info exists ${ns}::cluster_keys] {
      set keys [concat $keys [set ${ns}::cluster_keys]]
    }
    return $keys
  }

  #
  # sql_ctable_makekey
  #
  proc cass_ctable_makekey {level ns cmd args} {
    if {[info exists ${ns}::cluster_keys]} {
      set key _key
    } else {
      set key [set ${ns}::partition_key]
    }

    if {[llength $args] == 1} {
      set args [lindex $args 0]
    }

    array set array $args

    if {[info exists array($key)]} {
      return $array($key)
    }

    return -code error "No key in list"
  }

  #
  # cass_ctable_unimplemented
  #
  proc cass_ctable_unimplemented {level ns cmd args} {
    return -code error "Unimplemented command $cmd"
  }

  #
  # cass_ctable_ignore_null
  #
  proc cass_ctable_ignore_null {args} {
    return ""
  }

  #
  # cass_ctable_ignore_true
  #
  proc cass_ctable_ignore_true {args} {
    return 1
  }

  #
  # cass_ctable_ignore_false
  #
  proc cass_ctable_ignore_false {args} {
    return 0
  }

  #
  # cass_create_cql - internal helper routine
  #
  proc cass_create_cql {ns val slist} {
    if {![llength $slist]} {
      set slist [set ${ns}::fields]
    }

    set key [set ${ns}::partition_key]
    if [info exists ${ns}::types($key)] {
      set type [set ${ns}::types($key)]
    } else {
      set type text; # PUNT
    }

    foreach arg $slist {
      if {[info exists ${ns}::alias($arg)]} {
	lappend select [set ${ns}::alias($arg)]
      } else {
	lappend select $arg
      }
    }

    set cql "SELECT [join $select ,] FROM [set ${ns}::table_name]"
    append cql " WHERE $key = [::casstcl::quote $val $type]"
    append cql " LIMIT 1;"

    return $sql
  }

  #
  # cass_ctable_get - implement ctable get operation on a postgres table
  #
  # Get list - return empty list for no data, SQL error is error
  #
  proc cass_ctable_get {level ns cmd val args} {
    set cql [cass_create_cql $ns $val $args]
    set result ""

    if {![cass_get_one_tuple $cql result]} {
      error $result
    }

    return $result
  }

# WORKING

  #
  # sql_ctable_array_get
  #
  # Get name-value list - return empty list for no data, SQL error is error
  #
  proc sql_ctable_array_get {level ns cmd val args} {
    set sql [sql_create_sql $ns $val $args]

    pg_select -withoutnulls -nodotfields [conn] $sql row {
	return [array get row]
    }

    return [list]
  }


  #
  # sql_ctable_array_get_with_nulls
  #
  # Get name-value list - return empty list for no data, SQL error is error
  #
  proc sql_ctable_array_get_with_nulls {level ns cmd val args} {
    set sql [sql_create_sql $ns $val $args]

    pg_select -nodotfields [conn] $sql row {
	return [array get row]
    }

    return [list]
  }

  #
  # sql_ctable_exists - implement a ctable exists method for SQL tables
  #
  proc sql_ctable_exists {level ns cmd val} {
    set sql "SELECT [set ${ns}::key] FROM [set ${ns}::table_name]"
    append sql " WHERE [set ${ns}::key] = [pg_quote $val]"
    append sql " LIMIT 1;"
    # debug "\[pg_exec \[conn] \"$sql\"]"

    set pg_res [pg_exec [conn] $sql]
    if {![set ok [string match "PGRES_*_OK" [pg_result $pg_res -status]]]} {
      set err [pg_result $pg_res -error]
      set errinf "$err\nIn $sql"
    } else {
      set result [pg_result $pg_res -numTuples]
    }

    pg_result $pg_res -clear

    if {!$ok} {
      return -code error -errorinfo $errinf $err
    }
    return $result
  }

  #
  # sql_ctable_count - implement a ctable count method for SQL tables
  #
  proc sql_ctable_count {level ns cmd args} {
    set sql "SELECT COUNT([set ${ns}::key]) FROM [set ${ns}::table_name]"

    if {[llength $args] == 1} {
      append sql " WHERE [set ${ns}::key] = [pg_quote $val]"
    }

    append sql ";"
    return [lindex [cql_get_one_tuple $sql] 0]
  }

  #
  # sql_ctable_fields - implement a ctables fields method for SQL tables
  #
  proc sql_ctable_fields {level ns cmd args} {
    return [set ${ns}::fields]
  }

  #
  # sql_ctable_type - implement a ctables "type" method for SQL tables
  #
  proc sql_ctable_type {level ns cmd args} {
    return sql:///[set ${ns}::table_name]
  }

  #
  # sql_ctable_fieldtype - implement a ctables "fieldtype" method for SQL tables
  #
  proc sql_ctable_fieldtype {level ns cmd field} {
    if {![info exists ${ns}::types($field)]} {
      return -code error "No such field: $field"
    }
    return [set ${ns}::types($field)]
  }

  #
  # sql_ctable_search - implement a ctable search method for SQL tables
  #
  proc sql_ctable_search {level ns cmd args} {
    array set search $args

    if {![info exists search(-code)] &&
	![info exists search(-key)] &&
	![info exists search(-array)] &&
	![info exists search(-array_get)] &&
	![info exists search(-array_get_with_nulls)] &&
	![info exists search(-array_with_nulls)]} {
	set search(-countOnly) 1
    }

    set sql [${ns}::search_to_sql search]
    if {[info exists search(-countOnly)]} {
      return [lindex [sql_get_one_tuple $sql] 0]
    }

    set code {}
    set array ${ns}::select_array

    if {[info exists search(-array)]} {
        set array $search(-array)
    }
    if {[info exists search(-array_with_nulls)]} {
      set array $search(-array_with_nulls)
    }

    if {[info exists search(-array_get_with_nulls)]} {
      lappend code "set $search(-array_get_with_nulls) \[array get $array]"
    }

    if {[info exists search(-array_get)]} {
      lappend code "set $search(-array_get) \[array get $array]"
    }

    if {[info exists search(-key)]} {
      lappend code "set $search(-key) \$${array}(__key)"
    }

    lappend code $search(-code)
    lappend code "incr ${ns}::select_count"
    set ${ns}::select_count 0

    set selectCommand [list pg_select]
    if {[info exists search(-array)] || [info exists search(-array_get)]} {
        lappend selectCommand "-withoutnulls"
    }
    lappend selectCommand "-nodotfields"
    lappend selectCommand [conn] $sql $array [join $code "\n"]

    #puts stderr "sql_ctable_search level $level ns $ns cmd $cmd args $args: selectCommand is $selectCommand"

    if {[catch {uplevel #$level $selectCommand} catchResult catchOptions]} {
	dict incr catchOptions -level 1
	return -options $catchOptions $catchResult
    }
    return [set ${ns}::select_count]
  }

  #
  # sql_ctable_foreach - implement a ctable foreach method for SQL tables
  #
  proc sql_ctable_foreach {level ns cmd keyvar value code} {
    set sql "SELECT [set ${ns}::key] FROM [set ${ns}::table_name]"
    append sql " WHERE [set ${ns}::key] ILIKE [::stapi::quote_glob $val];"
    set code "set $keyvar \[lindex $__key 0]\n$code"
    uplevel #$level [list pg_select -nodotfields [conn] $sql __key $code]
  }

  #
  # sql_ctable_destroy - implement a ctable destroy method for SQL tables
  #
  proc sql_ctable_destroy {level ns cmd args} {
    namespace delete $ns
  }

  #
  # sql_ctable_delete - implement a ctable delete method for SQL tables
  #
  proc sql_ctable_delete {level ns cmd key args} {
    set sql "DELETE FROM [set ${ns}::table_name] WHERE [set ${ns}::key] = [pg_quote $key];"
    return [exec_sql $sql]
  }

  #
  # sql_ctable_set - implement a ctable set method for SQL tables
  #
  proc sql_ctable_set {level ns cmd key args} {
    if {![llength $args]} {
      return
    }

    if {[llength $args] == 1} {
      set args [lindex $args 0]
    }

    foreach {col value} $args {
      if {[info exists ${ns}::sql($col)]} {
	set col [set ${ns}::sql($col)]
      }

      lappend assigns "$col = [pg_quote $value]"
      lappend cols $col
      lappend vals [pg_quote $value]
    }

    set sql "UPDATE [set ${ns}::table_name] SET [join $assigns ", "]"
    append sql " WHERE [set ${ns}::key] = [pg_quote $key];"
    set rows 0

    if {![exec_sql_rows $sql rows]} {
      return 0
    }

    if {$rows > 0} {
      return 1
    }

    lappend cols [set ${ns}::key]
    lappend vals [pg_quote $key]

    set sql "INSERT INTO [set ${ns}::table_name] ([join $cols ","]) VALUES ([join $vals ","]);"
    return [exec_sql $sql]
  }

  #
  # sql_ctable_store - implement a ctable store method for SQL tables
  #
  proc sql_ctable_store {level ns cmd args} {
    if {[llength $args] == 1} {
      set args [lindex $args 0]
    }
    return [
      eval [list sql_ctable_set $level $ns $cmd [
	sql_ctable_makekey $level $ns $cmd $args
      ]] $args
    ]
  }

  #
  # sql_ctable_needs_quoting
  #
  proc sql_ctable_needs_quoting {level ns cmd args} { sql_ctable_unimplemented }

  #
  # sql_ctable_names
  #
  proc sql_ctable_names {level ns cmd args} { sql_ctable_unimplemented }

  #
  # sql_ctable_read_tabsep
  #
  proc sql_ctable_read_tabsep {level ns cmd args} { sql_ctable_unimplemented }

  #
  # search_to_sql
  #
  # This is never evaluated directly, it's only copied into a namespace
  # with [info body], so variables are from $ns and anything in ::stapi
  # needs direct quoting
  #
  proc search_to_sql {_req} {
    upvar 1 $_req req
    variable key
    variable table_name
    variable fields

    set select {}
    if {[info exists req(-countOnly)]} {
      lappend select "COUNT($key) AS count"
    } else {
      if {[info exists req(-key)]} {
	if {[info exists sql($key)]} {
	  lappend select "$sql($key) AS __key"
	} else {
          lappend select "$key AS __key"
	}
      }

      if {[info exists req(-fields)]} {
        set cols $req(-fields)

	  foreach col $cols {
	    if {[info exists sql($col)]} {
	      lappend select "$sql($col) AS $col"
	    } else {
	      lappend select $col
	    }
	  }
      } else {
	# they want all fields
        lappend select *
      }
    }
  
    set where {}
    if {[info exists req(-glob)]} {
      lappend where "$key LIKE [quote_glob $req(-glob)]"
    }
  
    if {[info exists req(-compare)]} {
      foreach tuple $req(-compare) {
	foreach {op col v1 v2} $tuple break

	if {[info exists sql($col)]} {
	  set col $sql($col)
	}

	switch -exact -- [string tolower $op] {
	  false {
	      lappend where "$col = FALSE"
	  }

	  true {
	      lappend where "$col = TRUE"
	  }

	  null {
	      lappend where "$col IS NULL"
	  }

	  notnull {
	      lappend where "$col IS NOT NULL"
	  }

	  < {
	      lappend where "$col < [pg_quote $v1]"
	  }

	  <= {
	      lappend where "$col <= [pg_quote $v1]"
	  }

	  = {
	      lappend where "$col = [pg_quote $v1]"
	  }

	  != {
	      lappend where "$col <> [pg_quote $v1]"
	  }

	  <> {
	      lappend where "$col <> [pg_quote $v1]"
	  }

	  >= {
	      lappend where "$col >= [pg_quote $v1]"
	  }

	  > {
	      lappend where "$col > [pg_quote $v1]"
	  }

	  imatch {
	      lappend where "$col ILIKE [::stapi::quote_glob $v1]"
	  }

	  -imatch {
	      lappend where "NOT $col ILIKE [::stapi::quote_glob $v1]"
	  }

	  match {
	      lappend where "$col ILIKE [::stapi::quote_glob $v1]"
	  }

	  notmatch {
	      lappend where "NOT $col ILIKE [::stapi::quote_glob $v1]"
	  }

	  xmatch {
	      lappend where "$col LIKE [::stapi::quote_glob $v1]"
	  }

	  -xmatch {
	      lappend where "NOT $col LIKE [::stapi::quote_glob $v1]"
	  }

	  match_case {
	      lappend where "$col LIKE [::stapi::quote_glob $v1]"
	  }

	  notmatch_case {
	    lappend where "NOT $col LIKE [::stapi::quote_glob $v1]"
	  }

	  umatch {
	    lappend where "$col LIKE [::stapi::quote_glob [string toupper $v1]]"
	  }

	  -umatch {
	    lappend where "NOT $col LIKE [
				::stapi::quote_glob [string toupper $v1]]"
	  }

	  lmatch {
	    lappend where "$col LIKE [::stapi::quote_glob [string tolower $v1]]"
	  }

	  -lmatch {
	    lappend where "NOT $col LIKE [
				::stapi::quote_glob [string tolower $v1]]"
	  }

	  range {
	    lappend where "$col >= [pg_quote $v1]"
	    lappend where "$col < [pg_quote $v2]"
	  }

	  in {
	    foreach v $v1 {
	      lappend q [pg_quote $v]
	    }
	    lappend where "$col IN ([join $q ","])"
	  }
	}
      }
    }
  
    set order {}
    if {[info exists req(-sort)]} {
      foreach field $req(-sort) {
	set desc ""

	if {[regexp {^-(.*)} $field _ field]} {
	  set desc " DESC"
	}

	if {[info exists sql(field)]} {
	  lappend order "$sql($field)$desc"
	} else {
	  lappend order "$field$desc"
	}
      }
    }
  
    # NB include a space for load balancing - total kludge, please remove asap
    set sql " SELECT [join $select ","] FROM $table_name"

    if {[llength $where]} {
      append sql " WHERE [join $where " AND "]"
    }

    if {[llength $order]} {
      append sql " ORDER BY [join $order ","]"
    }

    if {[info exists req(-limit)]} {
      append sql " LIMIT $req(-limit)"
    }

    if {[info exists req(-offset)]} {
      append sql " OFFSET $req(-offset)"
    }

    append sql ";"

  
    return $sql
  }

  #
  # cass_get_one_tuple
  #
  # Get one tuple from request in array-get form
  # Two calling sequences:
  #   set result [cass_get_one_tuple $cql]
  #      No data is an error (No Match)
  #   set status [cass_set_one_tuple $cql result]
  #      status ==  1 - success
  #      status == -1 - No data,  *result not modified*
  #      status ==  0 - SQL error, result is error string
  #
  proc cass_get_one_tuple {req {_result ""}} {
    if {[string length $_result]} {
      upvar 1 $_result result
    }

    set future [[cass] async $req]
    $future wait

    if {[$future status] != "CASS_OK"} {
      set status 0
      set err [$future error_message]
      set result $err
    } else {
      set count 0
      $future foreach row {
        incr count
        set result [array get $row]
        break
      }
      if {$count} {
        set status 1
      } else {
        set status -1
  	set err "No Match"
      }
    }

    $future delete

    if {[string length $_result]} {
      return $status
    }
      
    if {$status <= 0} {
      set errinf "$err\nIn $req"
      return -code error -errorinfo $errinf $err
    }

    return $result
  }

  #
  # quote_glob - 
  #
  proc quote_glob {pattern} {
    regsub -all {[%_]} $pattern {\\&} pattern
    regsub -all {@} $pattern {@%} pattern
    regsub -all {\\[*]} $pattern @_ pattern
    regsub -all {[*]} $pattern "%" pattern
    regsub -all {@_} $pattern {*} pattern
    regsub -all {\\[?]} $pattern @_ pattern
    regsub -all {[?]} $pattern "_" pattern
    regsub -all {@_} $pattern {?} pattern
    regsub -all {@%} $pattern {@} pattern
    return [pg_quote $pattern]
  }

  #
  # connect_sql
  #
  # Helper routine to shortcut the business of creating a URI and connecting
  # with the same keys. Using this implicitly pulls in stapi::extend inside connect
  # if it hasn't already been pulled in.
  #
  # Eg: ::stapi::connect_sql my_table {index} -cols {index name value}
  #
  proc connect_sql {table keys args} {
    lappend make make_sql_uri $table -keys $keys
    set uri [$make {*}$args]
    return [connect $uri -keys $keys]
  }
}

package provide st_client_cassandra 1.0.0

# vim: set ts=8 sw=4 sts=4 noet :
