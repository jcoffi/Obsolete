#!/bin/bash

VASTOOLLOC=/opt/quest/bin/vastool
VASGRPLOC=/opt/quest/bin/vgptool
VASDNSLOC=/opt/quest/sbin/dnsupdate
VASRPTLOG=/tmp/vas.log
VASERRLOG=/tmp/err.log
RPTERRORTO=CloudInfrastructure@company.com
INSTNAME=`hostname -s`
if [ -f /etc/default/vas_setup ]; then
  . /etc/default/vas_setup
else
  exitmail
fi
if [ -f $VASRPTLOG ]; then
  rm -f $VASRPTLOG $VASERRLOG
fi

exitemail () # Sub rutine to send fail to join email.
{
/bin/mail -s "VAS Error for $INSTNAME" $RPTERRORTO << EOF
Error adding $INSTNAME to the forest!
Please check the system and fix the issue.
Errors are logged to $VASERRLOG for processing.
EOF
}

# This section updates the SSH daemon to allow password access.
if [ "$(grep '#ChallengeResponseAuthentication' /etc/ssh/sshd_config | awk '{ print $2 }')" == "yes" ]; then
   echo "Updating SSH conf." >> $VASRPTLOG
   sed -i 's/#ChallengeResponseAuthentication yes/ChallengeResponseAuthentication yes/g' /etc/ssh/sshd_config
   sed -i 's/ChallengeResponseAuthentication no/#ChallengeResponseAuthentication no/g' /etc/ssh/sshd_config
   service sshd restart
fi

# This section check to see it the system has been configured for VAS to manage sudo and sudoers systems.
if [ `grep libsudo_vas.so /etc/sudoers > /dev/null` ] ; then
   echo "Updating sudo conf." >> $VASRPTLOG
   $VASTOOLLOC configure sudo -V /usr/sbin/visudo -f /etc/sudoers
fi

# This section Joins the system to the domain correctly.
if [ `echo $INSTNAME | grep "-"` ]; then
   SEC1=`echo $INSTNAME | cut -d"-" -f1`
   SEC2=`echo $INSTNAME | cut -d"-" -f2`
   SEC3=`echo $INSTNAME | cut -d"-" -f3`
   SEC4=`echo $INSTNAME | cut -d"-" -f4`
else
   SEC1=${INSTNAME:0:3}
   SEC2=${INSTNAME:3:3}
   SEC3=${INSTNAME:6:3}
   SEC4=${INSTNAME:9:3}
fi

echo "$SEC2"

case $SEC1 in
  PRD|prd|PQA|pqa|PST|pst|AUX|aux|DRP|drp|COM|com|AUT|aut|PPR|ppr)
    FMODOMAIN=corporate.company.com
    SFMODOMAIN=management.company.com,external.company.com
    FMOOU=Production
    FMODC=corporate
    ;;
  DEV|dev|POC|poc|UAT|uat|TES|tes|TST|tst|SIT|sit|UAT|uat|PPD|ppd|TMP|tmp|REG|reg|TEST|test)
    FMODOMAIN=corporate.company.com
    SFMODOMAIN=management.company.com,external.company.com
    FMOOU=Non-Production
    FMODC=corporate
    ;;
  STG|stg)
    FMODOMAIN=corporate.company.com
    SFMODOMAIN=management.company.com,external.company.com
    FMOOU=Staging
    FMODC=corporate
    ;;
  DMZ|dmz)
    FMODOMAIN=external.company.com
    SFMODOMAIN=management.company.com,corporate.company.com
    FMOOU=Production
    FMODC=external
    ;;
  *)
    exitemail
    exit 1
esac

#      add the system to the STG system.
echo "Joining the system to the Staging OU to get connectivity." >> $VASRPTLOG
echo "$VASJOINPASS" | $VASTOOLLOC -s -u $VASJOINUSER \
     join --skip-config -n $INSTNAME -f -c OU=POSIX,OU=Staging,OU=Servers,OU=Devices,DC=$FMODC,DC=company,DC=com $FMODOMAIN
if [ $? -ne 0 ] ;then
   exitemail
   exit 1
fi

# Pull the group and check it against the 2nd field of the system to connect
echo "Testing for OU in AD." >> $VASRPTLOG
echo "$VASJOINPASS" | $VASTOOLLOC -s -u $VASJOINUSER \
     search -q -U GC://@corporate.company.com -b "OU=$SEC2,OU=POSIX,OU=$FMOOU,OU=Servers,OU=Devices,DC=$FMODC,DC=company,DC=com"
if [ $? -eq 0 ];  then
# this will unjoin the system from the STG OU to allow it to rejoin it to the corrct ou.
   echo "$VASJOINPASS" | $VASTOOLLOC -s -u $VASJOINUSER unjoin
#      link this system to the AD OU for the application.
   echo "Joining the system to the AD System." >> $VASRPTLOG
   echo "$VASJOINPASS" | $VASTOOLLOC -s -u $VASJOINUSER \
        join -f -c OU=$SEC2,OU=POSIX,OU=$FMOOU,OU=Servers,OU=Devices,DC=$FMODC,DC=company,DC=com -r $SFMODOMAIN $FMODOMAIN 1>>$VASRPTLOG 2>>$VASERRLOG
   if [ $? -ne 0 ] ;then
      exitemail
      exit 1
   fi
else
   echo "Leaving the system in the Staging OU the App not found." >> $VASRPTLOG
fi

if [ "$(grep 'default_etypes' /etc/opt/quest/vas/vas.conf | awk '{ print $3 }' | grep arcfour-hmac-md5)" == "arcfour-hmac-md5" ]; then
   echo "Updating the vas.conf for the correct keys." >> $VASRPTLOG
   sed -i 's/default_etypes = arcfour-hmac-md5/default_etypes = aes256-cts-hmac-sha1-96/g' /etc/opt/quest/vas/vas.conf
   sed -i 's/default_etypes_des = des-cbc-crc/default_etypes = aes128-cts-hmac-sha1-96/g' /etc/opt/quest/vas/vas.conf
   service vasd restart
fi

$VASDNSLOC `hostname -I`
$VASGRPLOC register
$VASGRPLOC apply
$VASTOOLLOC configure vas vasd timesync-interval 0
$VASTOOLLOC flush
