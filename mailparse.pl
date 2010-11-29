#!/usr/bin/perl
#######################################################################
#
#                   simple email 2 fax gateway for asterisk
#
#  mailparse is a select-based [blocking] server. It reads email msg
#  sent by email2fax.pl from socket, parses it using Mail::Message
#  to TIFF email attachment, and TO:<fax num> and FROM: <email addr>.
#  TIFF attachment, fax num and from email address are sent back to the 
#  email2fax client program.
#
#  *** Legal ****
#
#  Written by Konstantin Antselovich <konstantin@antselovich.com>
#  (C) 2009-2010. 
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  This program is free software; you can redistribute it
#  and/or modify it under the terms of the GNU General Public
#  License as published by the Free Software Foundation; version 2
#  of the License.  http://www.gnu.org/licenses/gpl-2.0.txt
#
#
#######################################################################

use strict;
use warnings;

use Fcntl; 
use Socket;
use POSIX;
use IO::Socket;
use IO::Select;

use MIME::Base64 qw(encode_base64);

use Mail::Message;
use Mail::Address;

use constant true => 1;
use constant false => 0;
use constant none => undef;


my $data = {};

my $CONFIG = {
	DEBUG=>true,
	PORT=>"7777",
	LISTEN_QUEUE=>16,
	FAX_AREA_CODE=>323,
	FAX_COUNTRY_CODE=>1,
};

my $server_conn  = new IO::Socket::INET ( 
                                          LocalPort => $CONFIG->{PORT}, 
                                          Proto     => 'tcp', 
                                          Listen    => $CONFIG->{LISTEN_QUEUE}, 
                                          Reuse     => true,
					  Blocking  => false, 
                                        ) or die "cannot open socket $!\n";
my $socket_set = new IO::Select($server_conn);

## main loop 
while(my @ready = $socket_set->can_read() ) {
	foreach my $conn (@ready) {
		if ($conn == $server_conn) {
			# create new socket
			my $new_sock = $conn->accept();
			$socket_set->add($new_sock);	
		} else {
		   if (my $buff = <$conn>){  # read data
			read_data($conn,$buff);
		   } elsif($conn){
 			$socket_set->remove($conn) or warn "cannot remove connection $!\n";
			process_data($conn);	
			warn "data was processed\n" if $CONFIG->{DEBUG};
			close($conn) or warn "cannot close connection $!\n";
		   } else {
			warn "ERROR lost connection\n";
		   } 
		}
	}
}
  
## reads data from the socket
sub read_data  
{
	my $conn = shift;
	my $buff = shift;
	
	warn "read " .length($buff). "bytes from $conn\n" if $CONFIG->{DEBUG} == 10;	
	if ($data->{$conn}) {
	   $data->{$conn} .= $buff; 	
	} else {
	   $data->{$conn} = $buff;	
	}

} # end read_data() 

## process data
sub process_data 
{
	my $conn = shift;
	print " received " . length($data->{$conn}). " chars for conn $conn\n";
	warn "processing msg\n";
	my $msg = Mail::Message->read($data->{$conn}) or warn "cannot process msg $!\n";
	my $faxnum = parse_faxnum($msg->to);
	my ($sender_base64,$sender_addr_base64) = parse_sender($msg->from);
        foreach my $part ($msg->parts()) {
		if ($part->contentType eq "image/tiff"){
		    warn "found tiff\n" if $CONFIG->{DEBUG};
		    if ($faxnum) { 
		    	print $conn "FAX/1.0 200 $faxnum $sender_base64 $sender_addr_base64 OK\n" or warn "cannot send data to conn $!\n";
		    	$part->print($conn) or warn "cannot send data$!\n";
		    	warn "data sent\n" if $CONFIG->{DEBUG};
		    }
		}
	}
	
	#$msg->print(\*STDOUT);
	#print "$data->{$conn}";
	# delete data
	undef($data->{$conn});
} #end of process_data()

# parse fax number 
sub parse_faxnum 
{ 
	my $to_header = shift;  
	return '' if not $to_header;
	my $faxnum = $to_header->user();
	# add country code and area code if needed
	$faxnum = $CONFIG->{FAX_COUNTRY_CODE} . $CONFIG->{FAX_AREA_CODE} . $faxnum if $faxnum =~ m/^[0-9]{7}$/;
	$faxnum = $CONFIG->{FAX_COUNTRY_CODE} . $faxnum if $faxnum =~ m/^[0-9]{10}$/;

	return $faxnum;
}

# parse sender address
sub parse_sender 
{
	my $from_header = shift;
	return '' if not $from_header;
	my $sender = $from_header->format;
	$sender =~ s/("|')//g; # delete all ' and " 
	$sender = encode_base64($sender);
	my $sender_addr = encode_base64($from_header->address);
	chomp $sender; chomp $sender_addr;
	return ($sender, $sender_addr);
}

# exit signal
sub shutdown 
{
	print "shutting down ...\n";
	exit;
}

