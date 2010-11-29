#!/bin/bash
#
# Init file for email2fax mailparse daemon
# Konstantin Antselovich <konstantin@antselovich.com> 
# (based on spamass-milter init.d script with minor modifications)
#
# chkconfig: - 80 20
# description: mailparse is a daemon which parses email messages for
#              email2fax script
#
# processname: mailparse
# config: /etc/sysconfig/mailparse
# pidfile: /var/run/mailparse

source /etc/rc.d/init.d/functions
source /etc/sysconfig/network

# Check that networking is up.
[ ${NETWORKING} = "no" ] && exit 0

[ -x /usr/local/bin/mailparse ] || exit 1

### Default variables
SYSCONFIG="/etc/sysconfig/mailparse"

### Read configuration
[ -r "$SYSCONFIG" ] && source "$SYSCONFIG"

### add local bin to PATH
export PATH=$PATH:/usr/local/bin

RETVAL=0
prog="mailparse"
desc="email2fax mail parsing daemon"

start() {
	echo -n $"Starting $desc ($prog): "
	$prog & 
	RETVAL=$?
	echo
	[ $RETVAL -eq 0 ] && touch /var/lock/subsys/$prog
	return $RETVAL
}

stop() {
	echo -n $"Shutting down $desc ($prog): "
	killproc $prog
	killproc ${prog}.pl
	RETVAL=$?
	echo
	[ $RETVAL -eq 0 ] && rm -f /var/lock/subsys/$prog
	return $RETVAL
}

restart() {
	stop
	start
}

case "$1" in
  start)
	start
	;;
  stop)
	stop
	;;
  restart|reload)
	restart
	;;
  condrestart)
	[ -e /var/lock/subsys/$prog ] && restart
	RETVAL=$?
	;;
  status)
	status $prog
	RETVAL=$?
	status ${prog}.pl
	RETVAL=$?
	;;
  *)
	echo $"Usage: $0 {start|stop|restart|condrestart|status}"
	RETVAL=1
esac

exit $RETVAL
