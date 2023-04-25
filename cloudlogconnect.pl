#!/usr/bin/perl
use warnings;
use strict;

my $verbose=0;

my $rigFreq=0;
my $rigOldFreq=1;
my $rigMHz=0;
my $rigOldMHz=1;
my $script_call = "";


my $rigMode="MATCH";
my $rigOldMode="NO MATCH";
my $rigControlSoftware;

my $polling = 5;
my $polling_cli = 0;
my $min10 = 0;
my $nn=0;
my @array;
my $entry;
my $data;

my $par;
my $cloudlogRadioId;
my $cloudlogApiKey;
my $cloudlogApiUrl;
my $host;
my $port;
my $debug;

	# get script name
	my $scriptname = $0;
	my $path = ($scriptname =~ /(.*)\/([\w]+).pl/s)? $1 : "undef";
	$path = $path . "/";
	$scriptname = $2;
	my $tm = localtime(time);
	
	# Use loop to print all args stored in an array called @ARGV
	my $total = $#ARGV + 1;
	my $counter = 1;
	foreach my $a(@ARGV) {
		print "Arg # $counter : $a\n" if ($verbose == 7);
		$counter++;
		if (substr($a,0,2) eq "v=") {
			$verbose = substr($a,2,1);
			print "Debug On, Level: $verbose\n" if $verbose;
		}
		if (substr($a,0,2) eq "p=") {
			$polling_cli = substr($a,2,1);
			printf "Poll rig every %ds\n", $polling_cli if $verbose;
		}
	}
	print "Total args passed to $scriptname : $total \n" if $verbose;

	my $confdatei = $path . $scriptname . ".conf";
	open(INPUT, $confdatei) or die "Fehler bei Eingabedatei: $confdatei\n";
		undef $/;#	
		$data = <INPUT>;
	close INPUT;
	print "Datei $confdatei erfolgreich geöffnet ($path)\n" if $verbose;
	@array = split (/\n/, $data);
	$nn=0;
	foreach $entry (@array) {
		if ((substr($entry,0,1) ne "#") && (substr($entry,0,1) ne "")) {
			printf "%d [%s]\n",$nn,$entry if $verbose;
			$par = ($entry =~ /([\w]+).*\=.*\"(.*)\"/s)? $2 : "undef";
			$cloudlogRadioId = $par if ($1 eq "cloudlogRadioId");
			$cloudlogApiKey = $par if ($1 eq "cloudlogApiKey");
			$cloudlogApiUrl = $par if ($1 eq "cloudlogApiUrl");
			$host = $par if ($1 eq "host");
			$port = $par if ($1 eq "port");
			$debug = $par if ($1 eq "debug");
			$rigControlSoftware = $par if ($1 eq "rigControlSoftware");
			$polling = $par if ($1 eq "polling");
		}
		++$nn;
	}
	$verbose = $debug if (!$verbose);
	$polling = $polling_cli if ($polling_cli);
	
	printf "Parameter: Key: %s ID: %s URL: %s Host: %s Port: %s Rig: %s Polling: %s Debug: %s\n",$cloudlogApiKey,$cloudlogRadioId,$cloudlogApiUrl,$host,$port,$rigControlSoftware,$polling,$verbose if $verbose;	
	
	if (($rigControlSoftware ne "fldigi") && ($rigControlSoftware ne "sparksdr")) {
		printf "wrong rigControlSoftware (%s), only \"fldigi\" or \"sparksdr\" are implemented\n",$rigControlSoftware;	
		exit (-1);
	}	
	if ($polling == 0) {
		print "Polling the rig every 0s is not allowed, setting to default value (5s)\n";
		$polling = 5;
	}	
	
	# send something every 10 minutes, to keep Cloudlog happy
	$min10 = 600/$polling;
	while (1) {
	    get_data_from_fldigi($host,$port) if ($rigControlSoftware eq "fldigi");
	    get_data_from_sparksdr($host,$port) if ($rigControlSoftware eq "sparksdr");
	    if (!$min10) {
		$rigOldFreq = 0;
		$min10 = 600/$polling;
	    }
	    else {
		--$min10;
	    }
	
	    if (($rigFreq ne $rigOldFreq) || ($rigMode ne $rigOldMode)) {
			# rig freq or mode changed, update Cloudlog
			printf "to Cloudlog rigFreq:%s rigMode:%s ($min10)\n",$rigFreq,$rigMode if $verbose;	
			$rigMHz = (length($rigFreq) < 8)? substr($rigFreq,0,1) : substr($rigFreq,0,2);
			print "$rigMHz : $rigOldMHz\n";
			if (($rigControlSoftware eq "fldigi") && ($rigMHz ne $rigOldMHz)) {
				$script_call = $path . "sparksdr_cli.pl mhz=" . $rigMHz;
				print "$script_call\n" if $verbose;
				`$script_call`;
			}	
			$rigOldMHz=$rigMHz;
			$rigOldFreq=$rigFreq;
			$rigOldMode=$rigMode;
			send_info_to_cloudlog();
	    }
	    sleep $polling;
	}


sub get_data_from_fldigi {
my $rpc;
my $cmd;
my $fldigihost = $_[0];
my $fldigiport = $_[1];

	$rpc = rpc_call("main.get_frequency",$fldigihost,$fldigiport);
    $rigFreq = ($rpc =~ /.*<value><double>([\d]+)./s)? $1 : "undef";
	printf "RPC Antwort QRG:%s\n",$rigFreq if $verbose;

	$rpc = rpc_call("rig.get_mode",$fldigihost,$fldigiport);
    $rigMode = ($rpc =~ /.*<value>([\w]+)<\/value>/s)? $1 : "undef";
	printf "RPC Antwort Mode:%s\n",$rigMode if ($verbose == 2);

	if (($rigMode eq "PKTUSB") || ($rigMode eq "PKTLSB")) {
		$rpc = rpc_call("modem.get_name",$fldigihost,$fldigiport);
		$rigMode = ($rpc =~ /.*<value>([\w]+)<\/value>/s)? $1 : "undef";
		printf "RPC Antwort Mode:%s\n",$rigMode if ($verbose == 2);
	}
	else {	
		if ($rigMode eq "CWR") { $rigMode = "CW"; }
		elsif ($rigMode eq "USB") { $rigMode = "SSB"; }
		elsif ($rigMode eq "LSB") { $rigMode = "SSB"; }
		elsif ($rigMode eq "RTTYR") { $rigMode = "RTTY"; }
	}	
	printf "Antwort angepasst Mode:%s\n",$rigMode if $verbose;
}

sub rpc_call {
my $rpc_answer;
my $rpcxml = "";
my $rpc_call = "";
    $rpcxml = sprintf("<?xml version=\"1.0\"?><methodCall><methodName>%s</methodName></methodCall>",$_[0]);
	$rpc_call= sprintf("curl -k --data \"%s\" \"%s:%s\" 2>/dev/null",$rpcxml,$_[1],$_[2]);
	printf "RPC: %s\n",$rpc_call if ($verbose == 2);
	$rpc_answer =`$rpc_call`;
	printf "RPC Antwort: %s\n",$rpc_answer if ($verbose == 2);
	return($rpc_answer);

}

sub get_data_from_sparksdr {
my $cmd;
my $tx;
my $rigMW;
my $rigWidth;
my $sparkhost = $_[0];
my $sparkport = $_[1];
    
    $cmd = "rigctl -r " . $sparkhost . ":" . $sparkport ." -m 2 f ";
    $tx =`$cmd`;
    $rigFreq = trim($tx);
    $cmd = "echo \"m\" | nc -w 1 " . $sparkhost . " " . $sparkport;
    $tx =`$cmd`;
    $rigMW = trim($tx);
    printf "rigFreq %s rigMW %s\n",$rigFreq,$rigMW if $verbose;	
    $rigMode = ($rigMW =~ /([\w]+)\n([\d]+)/s)? $1 : "undef";
    $rigWidth = $2;
   printf "rigFreq:%s rigMode:%s rigWidth:%s ($min10)\n",$rigFreq,$rigMode,$rigWidth if $verbose;	
}

sub send_info_to_cloudlog {
my $apicall;
my $apistring_fix = sprintf("{\\\"key\\\":\\\"%s\\\",\\\"radio\\\":\\\"%s\\\",\\\"frequency\\\":\\\"%s\\\",\\\"mode\\\":\\\"%s\\\"}",$cloudlogApiKey,$cloudlogRadioId,$rigFreq,$rigMode);
    $apicall = sprintf("curl --silent --insecure --header \"Content-Type: application/json\" --request POST --data \"%s\" %s >/dev/null 2>&1\n",$apistring_fix,$cloudlogApiUrl);
	printf "ApiCall %s\n",$apicall if ($verbose == 2);
	`$apicall`;
}

sub trim {
	my $string = $_[0];
	$string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

