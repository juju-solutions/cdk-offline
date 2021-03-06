#!/bin/bash

set -eux

VPC_ID=$1
APT_MIRROR=$2
INSECURE_REGISTRY=$3
INSECURE_REGISTRY_PORT=$4

[ -z "$VPC_ID" ] && echo "Usage: install-squid.sh VPC_ID APT_MIRROR INSECURE_REGISTRY INSECURE_REGISTRY PORT." && exit 1
[ -z "$APT_MIRROR" ] && echo "Usage: install-squid.sh VPC_ID APT_MIRROR INSECURE_REGISTRY INSECURE_REGISTRY PORT." && exit 1
[ -z "$INSECURE_REGISTRY" ] && echo "Usage: install-squid.sh VPC_ID APT_MIRROR INSECURE_REGISTRY INSECURE_REGISTRY PORT." && exit 1
[ -z "$INSECURE_REGISTRY_PORT" ] && echo "Usage: install-squid.sh VPC_ID APT_MIRROR INSECURE_REGISTRY INSECURE_REGISTRY PORT." && exit 1

sudo apt-add-repository -y ppa:juju/stable
sudo apt update
sudo apt install -y juju

juju add-credential aws

sudo apt install -y libssl-dev build-essential openssl

cd /tmp
wget http://www.squid-cache.org/Versions/v3/3.5/squid-3.5.13.tar.gz
tar -xf squid-3.5.13.tar.gz
cd squid-3.5.13

sudo ./configure --prefix=/usr --exec-prefix=/usr --libexecdir=/usr/lib64/squid --sysconfdir=/etc/squid --sharedstatedir=/var/lib --localstatedir=/var --libdir=/usr/lib64 --datadir=/usr/share/squid --with-logdir=/var/log/squid --with-pidfile=/var/run/squid.pid --with-default-user=squid --disable-dependency-tracking --enable-linux-netfilter --with-openssl --without-nettle

sudo make -j 4
sudo make install

sudo useradd -M squid
sudo chown -R squid:squid /var/log/squid /var/cache/squid
sudo chmod 750 /var/log/squid /var/cache/squid
sudo touch /etc/squid/squid.conf
sudo chown -R root:squid /etc/squid/squid.conf
sudo chmod 640 /etc/squid/squid.conf
sudo tee /etc/init.d/squid <<'EOF'
#! /bin/sh
#
# squid		Startup script for the SQUID HTTP proxy-cache.
#
# Version:	@(#)squid.rc  1.0  07-Jul-2006  luigi@debian.org
#
### BEGIN INIT INFO
# Provides:          squid
# Required-Start:    $network $remote_fs $syslog
# Required-Stop:     $network $remote_fs $syslog
# Should-Start:      $named
# Should-Stop:       $named
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Squid HTTP Proxy version 3.x
### END INIT INFO

NAME=squid
DESC="Squid HTTP Proxy"
DAEMON=/usr/sbin/squid
PIDFILE=/var/run/$NAME.pid
CONFIG=/etc/squid/squid.conf
SQUID_ARGS="-YC -f $CONFIG"

[ ! -f /etc/default/squid ] || . /etc/default/squid

. /lib/lsb/init-functions

PATH=/bin:/usr/bin:/sbin:/usr/sbin

[ -x $DAEMON ] || exit 0

ulimit -n 65535

find_cache_dir () {
	w=" 	" # space tab
        res=`$DAEMON -k parse -f $CONFIG 2>&1 |
		grep "Processing:" |
		sed s/.*Processing:\ // |
		sed -ne '
			s/^['"$w"']*'$1'['"$w"']\+[^'"$w"']\+['"$w"']\+\([^'"$w"']\+\).*$/\1/p;
			t end;
			d;
			:end q'`
        [ -n "$res" ] || res=$2
        echo "$res"
}

grepconf () {
	w=" 	" # space tab
        res=`$DAEMON -k parse -f $CONFIG 2>&1 |
		grep "Processing:" |
		sed s/.*Processing:\ // |
		sed -ne '
			s/^['"$w"']*'$1'['"$w"']\+\([^'"$w"']\+\).*$/\1/p;
			t end;
			d;
			:end q'`
	[ -n "$res" ] || res=$2
	echo "$res"
}

create_run_dir () {
	run_dir=/var/run/squid
	usr=`grepconf cache_effective_user proxy`
	grp=`grepconf cache_effective_group proxy`

	if [ "$(dpkg-statoverride --list $run_dir)" = "" ] &&
	   [ ! -e $run_dir ] ; then
		mkdir -p $run_dir
	  	chown $usr:$grp $run_dir
		[ -x /sbin/restorecon ] && restorecon $run_dir
	fi
}

start () {
	cache_dir=`find_cache_dir cache_dir`
	cache_type=`grepconf cache_dir`
	run_dir=/var/run/squid

	#
	# Create run dir (needed for several workers on SMP)
	#
	create_run_dir

	#
	# Create spool dirs if they don't exist.
	#
	if test -d "$cache_dir" -a ! -d "$cache_dir/00"
	then
		log_warning_msg "Creating $DESC cache structure"
		$DAEMON -z -f $CONFIG
		[ -x /sbin/restorecon ] && restorecon -R $cache_dir
	fi

	umask 027
	ulimit -n 65535
	cd $run_dir
	start-stop-daemon --quiet --start \
		--pidfile $PIDFILE \
		--exec $DAEMON -- $SQUID_ARGS < /dev/null
	return $?
}

stop () {
	PID=`cat $PIDFILE 2>/dev/null`
	start-stop-daemon --stop --quiet --pidfile $PIDFILE --exec $DAEMON
	#
	#	Now we have to wait until squid has _really_ stopped.
	#
	sleep 2
	if test -n "$PID" && kill -0 $PID 2>/dev/null
	then
		log_action_begin_msg " Waiting"
		cnt=0
		while kill -0 $PID 2>/dev/null
		do
			cnt=`expr $cnt + 1`
			if [ $cnt -gt 24 ]
			then
				log_action_end_msg 1
				return 1
			fi
			sleep 5
			log_action_cont_msg ""
		done
		log_action_end_msg 0
		return 0
	else
		return 0
	fi
}

cfg_pidfile=`grepconf pid_filename`
if test "${cfg_pidfile:-none}" != "none" -a "$cfg_pidfile" != "$PIDFILE"
then
	log_warning_msg "squid.conf pid_filename overrides init script"
	PIDFILE="$cfg_pidfile"
fi

case "$1" in
    start)
	res=`$DAEMON -k parse -f $CONFIG 2>&1 | grep -o "FATAL .*"`
	if test -n "$res";
	then
		log_failure_msg "$res"
		exit 3
	else
		log_daemon_msg "Starting $DESC" "$NAME"
		if start ; then
			log_end_msg $?
		else
			log_end_msg $?
		fi
	fi
	;;
    stop)
	log_daemon_msg "Stopping $DESC" "$NAME"
	if stop ; then
		log_end_msg $?
	else
		log_end_msg $?
	fi
	;;
    reload|force-reload)
	res=`$DAEMON -k parse -f $CONFIG 2>&1 | grep -o "FATAL .*"`
	if test -n "$res";
	then
		log_failure_msg "$res"
		exit 3
	else
		log_action_msg "Reloading $DESC configuration files"
	  	start-stop-daemon --stop --signal 1 \
			--pidfile $PIDFILE --quiet --exec $DAEMON
		log_action_end_msg 0
	fi
	;;
    restart)
	res=`$DAEMON -k parse -f $CONFIG 2>&1 | grep -o "FATAL .*"`
	if test -n "$res";
	then
		log_failure_msg "$res"
		exit 3
	else
		log_daemon_msg "Restarting $DESC" "$NAME"
		stop
		if start ; then
			log_end_msg $?
		else
			log_end_msg $?
		fi
	fi
	;;
    status)
	status_of_proc -p $PIDFILE $DAEMON $NAME && exit 0 || exit 3
	;;
    *)
	echo "Usage: /etc/init.d/$NAME {start|stop|reload|force-reload|restart|status}"
	exit 3
	;;
esac

exit 0
EOF
sudo chmod +x /etc/init.d/squid

sudo mkdir /etc/squid/ssl
cd /etc/squid/ssl
sudo openssl genrsa -out squid.key 2048
sudo openssl req -new -key squid.key -out squid.csr -subj "/C=XX/ST=XX/L=squid/O=squid/CN=squid"
sudo openssl x509 -req -days 3650 -in squid.csr -signkey squid.key -out squid.crt
sudo cat squid.key squid.crt | sudo tee squid.pem

sudo tee /etc/squid/squid.conf <<EOF
visible_hostname squid

# Handle redirection
url_rewrite_program /etc/squid/url-rewrite.py
url_rewrite_children 4

# Handling HTTP requests
http_port 3129 intercept
# security.ubuntu.com is only "allowed" in the sense that it will be redirected later.
acl allowed_http_sites dstdomain security.ubuntu.com
acl allowed_http_sites dstdomain $INSECURE_REGISTRY_IP
acl allowed_http_sites dstdomain $APT_MIRROR
acl allowed_http_sites dstdomain ec2.ap-southeast-2.amazonaws.com
http_access allow allowed_http_sites

#Handling HTTPS requests
https_port 3130 cert=/etc/squid/ssl/squid.pem ssl-bump intercept
acl SSL_port port 443
http_access allow SSL_port
acl allowed_https_sites ssl::server_name $APT_MIRROR
acl allowed_https_sites ssl::server_name ec2.ap-southeast-2.amazonaws.com
acl step1 at_step SslBump1
acl step2 at_step SslBump2
acl step3 at_step SslBump3
ssl_bump peek step1 all
ssl_bump peek step2 allowed_https_sites
ssl_bump splice step3 allowed_https_sites
ssl_bump terminate step2 all

http_access deny all
EOF

sudo tee /etc/squid/url-rewrite.py <<EOF
#!/usr/bin/env python3

import sys

def main():
    req = sys.stdin.readline()
    while req:
        url = req.split()[0]
        if 'security.ubuntu.com' in url:
            new_url = url.replace('security.ubuntu.com', '$APT_MIRROR')
            resp = 'OK status=302 url="%s"\n' % new_url
        else:
            resp = 'OK'
        sys.stdout.write('%s\n' % resp)
        sys.stdout.flush()
        req = sys.stdin.readline()

if __name__ == '__main__':
    main()
EOF

sudo chmod +x /etc/squid/url-rewrite.py

sudo iptables -t nat -A PREROUTING -p tcp --dport $INSECURE_REGISTRY_PORT -j REDIRECT --to-port 3129
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3129
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 3130

sudo systemctl daemon-reload
sudo systemctl restart squid

cd /home/ubuntu

mkdir juju-metadata

juju metadata generate-image \
	-d juju-metadata \
	-i ami-550c3c36 \
	-r ap-southeast-2 \
	-u https://ec2.ap-southeast-2.amazonaws.com \
	--virt-type hvm \
	--storage=ssd

juju bootstrap aws/ap-southeast-2 \
	--config vpc-id=$VPC_ID \
	--config vpc-id-force=true \
	--config test-mode=true \
	--to subnet=172.32.0.0/24 \
	--metadata-source /home/ubuntu/juju-metadata \
	--config apt-mirror=http://$APT_MIRROR/ubuntu/ \
	--config agent-stream=release --debug
