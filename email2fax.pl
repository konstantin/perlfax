#!/usr/bin/perl
#######################################################################
#
#                   simple email 2 fax gateway for asterisk
#
#  email2fax receives msg from MTA on standard input, uses
#  mailparse server to get TIFF attachment and FAX number,
#  creates call out file for asterisk, emails a notification
#  to the user.
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

use IO::Socket;
use IO::Select;
use MIME::Base64 qw(decode_base64);

use constant true      => 1;
use constant false     => 0;
use constant none      => undef;
use constant OK        => 200;

use constant reading   => 0;    # I/we have stopped reading data
use constant writing   => 1;    # I/we have stopped writing data
use constant using     => 2;    # I/we have stopped using this socket

use constant DO_NOT_CLOSE_STATUS_AND_EMAIL_FILES => true;

my $CONFIG = {
	MAIL_PARSER_HOST=>"smicro.myhome",
	PORT=>"7777",
	TEMP_DIR=>"/var/tmp",
	UUIDGEN=>"/usr/bin/uuidgen",
	SIP_CHANNEL=> 'gafachi',
	SIP_CALLER_ID=>9495964975, # number
	SIP_WAIT_TIME=>180, # 180
	SIP_MAX_RETRIES=>0, #0
	SIP_RETRY_TIME=>300,# 300
	SIP_DO_ARCHIVE=>0, # false
	SIP_CONTEXT=>"fax_out",# fax_out
	SIP_PRIORITY=>1, # 1
	SIP_IS_T38CALL=>1, # true
	SIP_ACCOUNT=>1234, # some ext number
	ASTERISK_USER=>"asterisk",  # asterisk
	ASTERISK_OUTGOING_DIR=>"/var/spool/asterisk/outgoing/",    # /var/spool/asterisk/outgoing
	EMAIL_FROM=>"Email 2 Fax System <NO_REPLY\@efax.fax>",
	SENDMAIL=>"/usr/sbin/sendmail",
	DEBUG=>true,
	LOG_FILE=>"/var/tmp/email2fax.log",
};

our $VERSION = '0.01';

my $parser  = new IO::Socket::INET (      PeerAddr  => $CONFIG->{MAIL_PARSER_HOST},
                                          PeerPort  => $CONFIG->{PORT}, 
                                          Proto     => 'tcp',
					  Type      => SOCK_STREAM,
                                    ) or die "cannot connect to the mail parser server $CONFIG->{MAIL_PARSER_HOST}:$CONFIG->{PORT}, $@\n";
## create temp files
my $files_obj = create_temp_files();
my $tiff_file = $files_obj->{FAX_FILE_H};
my $msg_file =  $files_obj->{MSG_FILE_H};

## read msg from STDIN into file
while(<STDIN>){
	print $msg_file $_;
}
## send msg to server, skip the 1st line
$msg_file = reopen_msg_file($files_obj);
my $line_num = 1;
while(<$msg_file>){ 
	print $parser $_ if $line_num > 1; # skip the 1st line   
	$line_num++;
}
$parser->shutdown(writing); 
log_debug("data sent, server replied\n");
my ($i,$body)=0;
my $proto = none;
while(<$parser>){
	if ( $i==0 ) {# 1st line
		# we decode protocol
		$proto = parse_fax_protocol($_);   
	        last if $proto->{STATUS} != OK;
	}  
	$body = true if m/^\s+$/;  
	print $tiff_file decode_base64($_) if $body; 
	$i++;
}
## some debugging info
log_debug("got fax num: ".$proto->{FAXNUM}."\n");
log_debug("got sender: ".$proto->{SENDER}."\n");
log_debug("got sender addr:  ".$proto->{SENDER_ADDR}."\n");
## write  call out file
write_call_file($files_obj, $proto);
## close open files
close_temp_files($files_obj,DO_NOT_CLOSE_STATUS_AND_EMAIL_FILES);
## ask asterisk to send a fax
notify_asterisk($files_obj);
# wait for asterisk status file
my $faxing_ended = false; 
my %faxing_status;
my $status_file_h = $files_obj->{STATUS_FILE_H};
while(not $faxing_ended) {
	while(<$status_file_h>) {
		my ($key, $value) = split(/\s/);
		$key =~ s/:// if $key; 
		if ($value) {
			$faxing_status{$key}=$value;
		} else {
			$faxing_status{$key}=0;
		}
		if ($key eq "END" and $value eq "OK") {
			$faxing_ended=true;
		}
	}
	sleep 1;
}
#
## send email to with the fax status
send_email($files_obj,$proto,\%faxing_status);
## close temp files
close_temp_files($files_obj);
## 
delete_temp_files($files_obj); 
## end
exit 0;

#################################################################################
## 				helper functions
#################################################################################

# create temp files
sub create_temp_files 
{
	my $uuid = `$CONFIG->{UUIDGEN}`; chomp $uuid;
	my $call_file = "$CONFIG->{TEMP_DIR}/email2fax-$uuid.call";      # call file that asterisk reads and generates outgoing call
	my $fax_file = "$CONFIG->{TEMP_DIR}/email2fax-$uuid.tiff";       # TIFF image file that asterisk will fax out
	my $status_file = "$CONFIG->{TEMP_DIR}/email2fax-$uuid.status";  # this file will be written by asterisk to indicate the status of the fax call 
	my $email_file = "$CONFIG->{TEMP_DIR}/email2fax-$uuid.email";    # email message that will be sent to the user to notify that the fax was sent OK/FAIL
	my $msg_file = "$CONFIG->{TEMP_DIR}/email2fax-$uuid.msg";	 # email message that we capture from the mail server
	my $log_file = "$CONFIG->{LOG_FILE}";				 # debug log
	open(my $call_file_h, ">",$call_file) or die "cannot create call file $call_file $!\n";
	open(my $fax_file_h,">",$fax_file) or die "cannot create fax file $fax_file $!\n";
	open(my $status_file_h,"+>",$status_file) or die "cannot create status file $status_file $!\n";
	open(my $email_file_h,">",$email_file) or die "cannot create email file $email_file $!\n";
	open(my $msg_file_h,"+>",$msg_file) or die "cannot create message file $msg_file $!\n";
	open(my $log_file_h,"+>",$log_file) or die "cannot create log file $log_file $!\n";
	return { 
		 CALL_FILE_H => $call_file_h,
		 CALL_FILE_NAME => $call_file, 
		 FAX_FILE_H=> $fax_file_h,
		 FAX_FILE_NAME=> $fax_file,
		 STATUS_FILE_H=> $status_file_h,
                 STATUS_FILE_NAME=> $status_file,
		 EMAIL_FILE_H=> $email_file_h,
                 EMAIL_FILE_NAME=> $email_file,
		 MSG_FILE_H=> $msg_file_h,
                 MSG_FILE_NAME=> $msg_file,
		 LOG_FILE_H=>$log_file_h,
		 LOG_FILE_NAME=>$CONFIG->{LOG_FILE},
	       } 
	        if $call_file_h and $fax_file_h and $status_file_h and $email_file_h and $msg_file_h and $log_file_h;
}

# reopens msg file for reading
sub reopen_msg_file
{
	my $files_obj = shift;
	my $msg_file = $files_obj->{MSG_FILE_NAME};
       	close($files_obj->{MSG_FILE_H}) or die "cannot  close msg file $files_obj->{MSG_FILE_NAME} $!\n";
	open(my $msg_file_h,"<",$msg_file) or die "cannot create message file $msg_file $!\n";
	if ($msg_file_h) {
		$files_obj->{MSG_FILE_H} = $msg_file_h;
		return $msg_file_h;
	}
	return none;	
}

# closes temp files
sub close_temp_files
{
	my $files_obj = shift;
	my $dont_close_status_and_email_files = shift;

	if ($files_obj->{CALL_FILE_H} and $files_obj->{FAX_FILE_H}) {
		close($files_obj->{CALL_FILE_H}) or die "cannot close call file $files_obj->{CALL_FILE_NAME} $!\n";
        	close($files_obj->{FAX_FILE_H}) or die "cannot  close fax file $files_obj->{FAX_FILE_NAME} $!\n";
        	close($files_obj->{MSG_FILE_H}) or die "cannot  close msg file $files_obj->{MSG_FILE_NAME} $!\n";
		$files_obj->{CALL_FILE_H} = none; 
		$files_obj->{FAX_FILE_H} = none;
		$files_obj->{MSG_FILE_H} = none;
	}
	if (not $dont_close_status_and_email_files and ($files_obj->{STATUS_FILE_H} and $files_obj->{EMAIL_FILE_H}) ) {
		close($files_obj->{STATUS_FILE_H}) or die "cannot  close status file $files_obj->{STATUS_FILE_NAME} $!\n";
		close($files_obj->{EMAIL_FILE_H}) or die "cannot  close email file $files_obj->{EMAIL_FILE_NAME} $!\n";
		close($files_obj->{LOG_FILE_H}) or die "cannot  close log file $files_obj->{LOG_FILE_NAME} $!\n";
		$files_obj->{STATUS_FILE_H} = none; 
		$files_obj->{EMAIL_FILE_H} = none; 
		$files_obj->{LOG_FILE_H} = none; 
	}
}

# parse fax proto 
sub parse_fax_protocol
{
	my $data = shift;
	chomp($data);
	my ($proto,$status,$faxnum,$sender_base64,$sender_addr_base64,$msg) = split(/\s/, $data);
	my ($proto_name,$proto_ver) = split(/\\/,$proto);

	my $proto_obj = {
		NAME=>$proto_name,
		VER =>$proto_ver,
		STATUS=>$status,
		FAXNUM=>$faxnum,
		SENDER=>decode_base64($sender_base64), 
		SENDER_ADDR=>decode_base64($sender_addr_base64),
		MSG=>$msg,
	};
	return $proto_obj;
}

# create dial out file
sub write_call_file 
{
	my ($files_obj, $proto_obj) = @_;
	my $call_out = '';
	my $call_file_h = $files_obj->{CALL_FILE_H};

	# create call out file content
	$call_out .= "Channel: SIP/".$proto_obj->{FAXNUM}."@".$CONFIG->{SIP_CHANNEL}."\n";
 	$call_out .= "CallerID: ".$CONFIG->{SIP_CALLER_ID}."\n"; # number
 	$call_out .= "WaitTime: ".$CONFIG->{SIP_WAIT_TIME}."\n"; # 180 
 	$call_out .= "MaxRetries: ".$CONFIG->{SIP_MAX_RETRIES}."\n"; #0
 	$call_out .= "RetryTime: ".$CONFIG->{SIP_RETRY_TIME}."\n";# 300
 	$call_out .= "Account:\n"; # empty
 	$call_out .= "Archive: ".$CONFIG->{SIP_DO_ARCHIVE}."\n"; # false
 	$call_out .= "Context: ".$CONFIG->{SIP_CONTEXT}."\n";# fax_out
 	$call_out .= "Extension: ".$proto_obj->{FAXNUM}."\n";# fax num
 	$call_out .= "Priority: ".$CONFIG->{SIP_PRIORITY}."\n"; # 1
 	$call_out .= "SetVar: SENDER=".$proto_obj->{SENDER}."\n";# Yourname <yourname@mydomain.com>
 	$call_out .= "SetVar: T38CALL=".$CONFIG->{SIP_IS_T38CALL}."\n"; # 1
 	$call_out .= "SetVar: LOCALSTATIONID=".$CONFIG->{SIP_CALLER_ID}."\n"; # number
 	$call_out .= "SetVar: TIFF=".$files_obj->{FAX_FILE_NAME}."\n"; # /tmp/fax_out_8db15599-c9d7-4b06-94a7-aeddbb1112e0.tiff 
 	$call_out .= "SetVar: STATUSF=".$files_obj->{STATUS_FILE_NAME}."\n"; # /tmp/fax_out_8db15599-c9d7-4b06-94a7-aeddbb1112e0.status 
 	$call_out .= "SetVar: ACCOUNT=".$CONFIG->{SIP_ACCOUNT}."\n"; # some ext number
 	$call_out .= "SetVar: REMOTESTATIONID=".$proto_obj->{FAXNUM}."\n"; # num
	# print content to call out file handle
	print $call_file_h $call_out or die "cannot write call out file: $files_obj->{CALL_FILE_NAME} $!\n"; 
}

# mv call out file
sub notify_asterisk
{
	my $files_obj = shift;
	# set asterisk permissions for files 
	system("chown", "$CONFIG->{ASTERISK_USER}:$CONFIG->{ASTERISK_USER}", "$files_obj->{FAX_FILE_NAME}");
	system("chown", "$CONFIG->{ASTERISK_USER}:$CONFIG->{ASTERISK_USER}", "$files_obj->{CALL_FILE_NAME}");
	system("chown", "$CONFIG->{ASTERISK_USER}:$CONFIG->{ASTERISK_USER}", "$files_obj->{STATUS_FILE_NAME}");
	# move call file to asterisk outgoing spool
	system("mv", "$files_obj->{CALL_FILE_NAME}", "$CONFIG->{ASTERISK_OUTGOING_DIR}");
}

# send mail out
sub send_email
{
	my $files_obj = shift;
	my $proto_obj = shift;
	my $faxing_status = shift;

	my $email_file_h = $files_obj->{EMAIL_FILE_H};
	my $email_msg = '';

	$email_msg .= "From: $CONFIG->{EMAIL_FROM}\n";
	$email_msg .= "To: $proto_obj->{SENDER}\n";
	$email_msg .= "Subject: Your fax to $proto_obj->{FAXNUM} of $faxing_status->{FAX_PAGES} pages ";
	$email_msg .= "WAS SENT SUCCESSFULLY\n" if $faxing_status->{STATUS} eq "OK";
	$email_msg .= "FAILED\n" if $faxing_status->{STATUS} eq "FAIL"; 
	$email_msg .= "\n\n";
	$email_msg .= "Your fax to $proto_obj->{FAXNUM}\n"; 
	$email_msg .= "of $faxing_status->{FAX_PAGES} pages "; 
        $email_msg .= "WAS SENT SUCCESSFULLY\n\n" if $faxing_status->{STATUS} eq "OK";
        $email_msg .= "FAILED\n\n" if $faxing_status->{STATUS} eq "FAIL";	
	$email_msg .= "Resolution: $faxing_status->{FAX_RESOLUTION}, Bitrate: $faxing_status->{FAX_BITRATE}, ";
        $email_msg .= "System status: $faxing_status->{FAX_ERROR}, Fax data: $faxing_status->{FAX_DATA}\n";	
	$email_msg .= "\n";	
	$email_msg .= "--\n";	
	$email_msg .= "Yours Email-2-Fax System.\n";	

	print $email_file_h $email_msg;
	return `$CONFIG->{SENDMAIL} $proto_obj->{SENDER_ADDR} < $files_obj->{EMAIL_FILE_NAME}`;
}

# delete files 
sub delete_temp_files
{
	my $files_obj = shift;
	unlink($files_obj->{FAX_FILE_NAME}) if( -e $files_obj->{FAX_FILE_NAME});
	unlink($files_obj->{STATUS_FILE_NAME}) if( -e $files_obj->{STATUS_FILE_NAME});
	unlink($files_obj->{EMAIL_FILE_NAME}) if( -e $files_obj->{EMAIL_FILE_NAME});
	unlink($files_obj->{MSG_FILE_NAME}) if( -e $files_obj->{MSG_FILE_NAME});
}

# write to debug log
sub log_debug 
{
	return if not $CONFIG->{DEBUG};
	my $msg = shift;
	my $log = $files_obj->{LOG_FILE_H};
	print $log "$$ $msg";
}
