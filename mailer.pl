#!/usr/bin/perl
#
# this is a test perl mailer program
#
use strict;
use warnings;

my $CONFIG = {
		LOG=>'/var/tmp/mailer.log',
	     };

open(my $log_h, "+>", $CONFIG->{LOG}) or die "cannot open config file $CONFIG->{LOG} for writing: $!\n";
# 1. write all arguments to log
my $count=1;
foreach my $arg (@ARGV) {
	print $log_h "$$ ARG $count = $arg\n";
	$count++;
}
# 2. write all STDIN to log
print $log_h "$$ ---- STDIN ----\n";
while(<STDIN>){
	print $log_h "$$ $_"; 
}
close($log_h) or die "cannot close config file $CONFIG->{LOG} : $!\n";
