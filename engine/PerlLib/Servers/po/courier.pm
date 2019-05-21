=head1 NAME

 Servers::po::courier - i-MSCP Courier IMAP/POP3 Server implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2019 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package Servers::po::courier;

use strict;
use warnings;
use Class::Autouse qw/ :nostat Servers::po::courier::installer Servers::po::courier::uninstaller /;
use File::Temp;
use iMSCP::Boolean;
use iMSCP::Config;
use iMSCP::Debug qw/ debug error getMessageByType /;
use iMSCP::Dir;
use iMSCP::EventManager;
use iMSCP::Execute 'execute';
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::Rights 'setRights';
use iMSCP::Service;
use List::MoreUtils 'uniq';
use Servers::mta;
use Sort::Naturally;
use Tie::File;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP Courier IMAP/POP3 Server implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners(\%events)

 Register setup event listeners

 Param iMSCP::EventManager \%events
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    my ( undef, $events ) = @_;

    Servers::po::courier::installer->getInstance()->registerSetupListeners(
        $events
    );
}

=item preinstall( )

 Process preinstall tasks

 Return int 0 on success, other on failure

=cut

sub preinstall
{
    my ( $self ) = @_;

    my $rs = $self->{'events'}->trigger( 'beforePoPreinstall', 'courier' );
    $rs ||= $self->stop();
    $rs ||= $self->{'events'}->trigger( 'afterPoPreinstall', 'courier' );
}

=item install( )

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my ( $self ) = @_;

    my $rs = $self->{'events'}->trigger( 'beforePoInstall', 'courier' );
    $rs ||= Servers::po::courier::installer->getInstance()->install();
    $rs ||= $self->{'events'}->trigger( 'afterPoInstall', 'courier' );
}

=item postinstall( )

 Process postinstall tasks

 Return int 0 on success, other on failure

=cut

sub postinstall
{
    my ( $self ) = @_;

    my $rs = $self->{'events'}->trigger( 'beforePoPostinstall', 'courier' );
    return $rs if $rs;

    local $@;
    eval {
        my @toEnableServices = (
            'AUTHDAEMON_SNAME', 'POPD_SNAME', 'IMAPD_SNAME'
        );
        my @toDisableServices = ();

        if ( $::imscpConfig{'SERVICES_SSL_ENABLED'} eq 'yes' ) {
            push @toEnableServices, 'POPD_SSL_SNAME', 'IMAPD_SSL_SNAME';
        } else {
            push @toDisableServices, 'POPD_SSL_SNAME', 'IMAPD_SSL_SNAME';
        }

        my $serviceMngr = iMSCP::Service->getInstance();
        for my $service ( @toEnableServices ) { ;
            $serviceMngr->enable( $self->{'config'}->{$service} );
        }

        for my $service ( @toDisableServices ) {
            $serviceMngr->stop( $self->{'config'}->{$service} );
            $serviceMngr->disable( $self->{'config'}->{$service} );
        }
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $rs = $self->{'events'}->register(
        'beforeSetupRestartServices',
        sub {
            push @{ $_[0] }, [
                sub { $self->start(); },
                'Courier IMAP/POP, Courier Authdaemon'
            ];
            0;
        },
        5
    );
    $rs ||= $self->{'events'}->trigger( 'afterPoPostinstall', 'courier' );
}

=item uninstall( )

 Process uninstall tasks

 Return int 0 on success, other on failure

=cut

sub uninstall
{
    my ( $self ) = @_;

    my $rs = $self->{'events'}->trigger( 'beforePoUninstall', 'courier' );
    $rs ||= Servers::po::courier::uninstaller->getInstance()->uninstall();
    $rs ||= $self->{'events'}->trigger( 'afterPoUninstall', 'courier' );
    return $rs if $rs;

    if ( iMSCP::Service->getInstance()->hasService(
        $self->{'config'}->{'AUTHDAEMON_SNAME'}
    ) ) {
        $self->{'restart'} = TRUE;
    } else {
        $self->{'restart'} = FALSE;
    }

    0;
}

=item setEnginePermissions( )

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
    my ( $self ) = @_;

    my $rs = $self->{'events'}->trigger( 'beforePoSetEnginePermissions' );
    return $rs if $rs;

    if ( -d $self->{'config'}->{'AUTHLIB_SOCKET_DIR'} ) {
        $rs ||= setRights( $self->{'config'}->{'AUTHLIB_SOCKET_DIR'}, {
            user  => $self->{'config'}->{'AUTHDAEMON_USER'},
            group => $self->{'mta'}->{'config'}->{'MTA_MAILBOX_GID_NAME'},
            mode  => '0750'
        } );
        return $rs if $rs;
    }

    $rs = setRights( "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/authmysqlrc", {
        user  => $self->{'config'}->{'AUTHDAEMON_USER'},
        group => $self->{'config'}->{'AUTHDAEMON_GROUP'},
        mode  => '0660'
    } );
    $rs ||= setRights( $self->{'config'}->{'QUOTA_WARN_MSG_PATH'}, {
        user  => $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'},
        group => $::imscpConfig{'ROOT_GROUP'},
        mode  => '0640'
    } );
    return $rs if $rs;

    if ( -f "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem" ) {
        $rs = setRights(
            "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem",
            {
                user  => $self->{'config'}->{'AUTHDAEMON_USER'},
                group => $self->{'config'}->{'AUTHDAEMON_GROUP'},
                mode  => '0600'
            }
        );
        return $rs if $rs;
    }

    $self->{'events'}->trigger( 'afterPoSetEnginePermissions' );
}

=item addMail( \%data )

 Process addMail tasks

 Param hash \%data Mail data
 Return int 0 on success, other on failure

=cut

sub addMail
{
    my ( $self, $data ) = @_;

    return 0 unless index( $data->{'MAIL_TYPE'}, '_mail' ) != -1;

    my $mailDir = "$self->{'mta'}->{'config'}->{'MTA_VIRTUAL_MAIL_DIR'}/$data->{'DOMAIN_NAME'}/$data->{'MAIL_ACC'}";
    my $mailUidName = $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'};
    my $mailGidName = $self->{'mta'}->{'config'}->{'MTA_MAILBOX_GID_NAME'};

    local $@;
    eval {
        for my $mailbox ( qw/ .Drafts .Junk .Sent .Trash / ) {
            iMSCP::Dir->new( dirname => "$mailDir/$mailbox" )->make( {
                user           => $mailUidName,
                group          => $mailGidName,
                mode           => 0750,
                fixpermissions => iMSCP::Getopt->fixPermissions
            } );

            for my $dir ( qw/ cur new tmp / ) {
                iMSCP::Dir->new( dirname => "$mailDir/$mailbox/$dir" )->make( {
                    user           => $mailUidName,
                    group          => $mailGidName,
                    mode           => 0750,
                    fixpermissions => iMSCP::Getopt->fixPermissions
                } );
            }
        }
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    my @subscribedFolders = qw/
        INBOX.Drafts INBOX.Junk INBOX.Sent INBOX.Trash
    /;
    my $subscriptionsFile = iMSCP::File->new(
        filename => "$mailDir/courierimapsubscribed"
    );

    if ( -f "$mailDir/courierimapsubscribed" ) {
        return 1 unless defined(
            my $subscriptionsFileContent = $subscriptionsFile->get()
        );

        if ( $subscriptionsFileContent ne '' ) {
            @subscribedFolders = nsort uniq(
                @subscribedFolders, split( /\n/, $subscriptionsFileContent
            ));
        }
    }

    $subscriptionsFile->set( ( join "\n", @subscribedFolders ) . "\n" );
    my $rs = $subscriptionsFile->save();
    $rs ||= $subscriptionsFile->owner( $mailUidName, $mailGidName );
    $rs ||= $subscriptionsFile->mode( 0640 );
    return $rs if $rs;

    if ( $data->{'MAIL_QUOTA'} ) {
        if ( $self->{'forceMailboxesQuotaRecalc'}
            || ( $self->{'execMode'} eq 'backend' && $data->{'STATUS'} eq 'tochange' )
            || !-f "$mailDir/maildirsize"
        ) {
            $rs = execute(
                [ 'maildirmake', '-q', "$data->{'MAIL_QUOTA'}S", $mailDir ],
                \my $stdout,
                \my $stderr
            );
            debug( $stdout ) if length $stdout;
            error( $stderr || 'Unknown error' ) if $rs;
            return $rs if $rs;

            my $file = iMSCP::File->new( filename => "$mailDir/maildirsize" );
            $rs ||= $file->owner( $mailUidName, $mailGidName );
            $rs = $file->mode( 0640 );
            return $rs if $rs;
        }

        return 0;
    }

    if ( -f "$mailDir/maildirsize" ) {
        $rs = iMSCP::File->new(
            filename => "$mailDir/maildirsize"
        )->delFile();
        return $rs if $rs;
    }

    0;
}

=item start( )

 Start courier servers

 Return int 0 on success, other on failure

=cut

sub start
{
    my ( $self ) = @_;

    my $rs = $self->{'events'}->trigger( 'beforePoStart' );
    return $rs if $rs;

    local $@;
    eval {
        my $serviceMngr = iMSCP::Service->getInstance();

        for my $service ( qw/
            AUTHDAEMON_SNAME
            POPD_SNAME
            IMAPD_SNAME
        / ) {
            $serviceMngr->start( $self->{'config'}->{$service} );
        }

        if ( $::imscpConfig{'SERVICES_SSL_ENABLED'} eq 'yes' ) {
            for my $service ( qw/
                POPD_SSL_SNAME
                IMAPD_SSL_SNAME
            / ) {
                $serviceMngr->start( $self->{'config'}->{$service} );
            }
        }
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $self->{'events'}->trigger( 'afterPoStart' );
}

=item stop( )

 Stop courier servers

 Return int 0 on success, other on failure

=cut

sub stop
{
    my ( $self ) = @_;

    my $rs = $self->{'events'}->trigger( 'beforePoStop' );
    return $rs if $rs;

    local $@;
    eval {
        my $serviceMngr = iMSCP::Service->getInstance();
        for my $service ( qw/
            AUTHDAEMON_SNAME
            POPD_SNAME
            POPD_SSL_SNAME
            IMAPD_SNAME
            IMAPD_SSL_SNAME /
        ) {
            $serviceMngr->stop( $self->{'config'}->{$service} );
        }
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $self->{'events'}->trigger( 'afterPoStop' );
}

=item restart( )

 Restart courier servers

 Return int 0 on success, other on failure

=cut

sub restart
{
    my ( $self ) = @_;

    my $rs = $self->{'events'}->trigger( 'beforePoRestart' );
    return $rs if $rs;

    local $@;
    eval {
        my @toRestartServices = qw/ AUTHDAEMON_SNAME POPD_SNAME IMAPD_SNAME /;
        if ( $::imscpConfig{'SERVICES_SSL_ENABLED'} eq 'yes' ) {
            push @toRestartServices, 'POPD_SSL_SNAME', 'IMAPD_SSL_SNAME';
        }

        my $serviceMngr = iMSCP::Service->getInstance();
        for my $service ( @toRestartServices ) {
            $serviceMngr->restart( $self->{'config'}->{$service} );
        }
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $self->{'events'}->trigger( 'afterPoRestart' );
}

=item getTraffic( $trafficDb [, $trafficDataSrc, $indexDb ] )

 Get IMAP/POP3 traffic data

 Param hashref \%trafficDb Traffic database
 Param string $logFile Path to SMTP log file from which traffic data must be extracted (only when self-called)
 Param hashref $trafficIndexDb Traffic index database (only when self-called)
 Return void, die on failure

=cut

sub getTraffic
{
    my ( $self, $trafficDb, $logFile, $trafficIndexDb ) = @_;

    $logFile ||= "$::imscpConfig{'TRAFF_LOG_DIR'}/$::imscpConfig{'MAIL_TRAFF_LOG'}";

    if ( -f -s $logFile ) {
        # We use an index database file to keep trace of the last processed log
        $trafficIndexDb or tie %{ $trafficIndexDb },
            'iMSCP::Config',
            fileName => "$::imscpConfig{'IMSCP_HOMEDIR'}/traffic_index.db",
            nodie    => TRUE;

        my ( $idx, $idxContent ) = (
            $trafficIndexDb->{'po_lineNo'} || 0,
            $trafficIndexDb->{'po_lineContent'}
        );

        # Create a snapshot of current log file state
        my $snapshotFH = File::Temp->new();
        iMSCP::File->new(
            filename => $logFile
        )->copyFile(
            $snapshotFH->filename(), { preserve => 'no' }
        ) == 0 or die( getMessageByType(
            'error', { amount => 1, remove => TRUE }
        ) || 'Unknown error' );

        # Tie the snapshot for easy handling
        tie my @snapshot, 'Tie::File', $snapshotFH,
            memory => 10_485_760 or die( sprintf(
            "Couldn't tie %s file", $snapshotFH
        ));

        # We keep trace of the index for the live log file only
        unless ( $logFile =~ /\.1$/ ) {
            $trafficIndexDb->{'po_lineNo'} = $#snapshot;
            $trafficIndexDb->{'po_lineContent'} = $snapshot[$#snapshot];
        }

        debug( sprintf(
            'Processing IMAP/POP3 logs from the %s file', $logFile
        ));

        # We have already seen the log file in the past. We must skip logs that were already processed
        if ( $snapshot[$idx] && $snapshot[$idx] eq $idxContent ) {
            debug( sprintf(
                'Skipping logs that were already processed (lines %d to %d)',
                1,
                ++$idx
            ));

            my $logsFound = ( @snapshot = @snapshot[$idx .. $#snapshot] ) > 0;
            untie( @snapshot );

            unless ( $logsFound ) {
                debug( sprintf(
                    'No new IMAP/POP3 logs found in %s file for processing',
                    $logFile
                ));
                $snapshotFH->close();
                return;
            }
        } elsif ( $logFile !~ /\.1$/ ) {
            debug( 'Log rotation has been detected. Processing last rotated log file first' );
            untie( @snapshot );
            $self->getTraffic( $trafficDb, $logFile . '.1', $trafficIndexDb );
        } else {
            untie( @snapshot );
        }

        while ( <$snapshotFH> ) {
            # Extract IMAP/POP3 traffic data
            #
            # Log line examples
            # Apr 21 15:14:44 www pop3d: LOGOUT, user=user@domain.tld, ip=[::ffff:192.168.1.1], port=[36852], top=0, retr=0, rcvd=6, sent=30, time=0, stls=1
            # Apr 21 15:14:55 www imapd: LOGOUT, user=user@domain.tld, ip=[::ffff:192.168.1.1], headers=0, body=0, rcvd=635, sent=1872, time=4477, starttls=1
            # Apr 21 15:23:12 www pop3d-ssl: LOGOUT, user=user@domain.tld, ip=[::ffff:192.168.1.1], port=[59556], top=0, retr=0, rcvd=12, sent=39, time=0, stls=1
            # Apr 21 15:24:36 www imapd-ssl: LOGOUT, user=user@domain.tld, ip=[::ffff:192.168.1.1], headers=0, body=0, rcvd=50, sent=374, time=10, starttls=1
            next unless /(?:imapd|pop3d(:?-ssl)):.*user=[^\@]+\@(?<domain>[^,]+).*rcvd=(?<rcvd>\d+).*sent=(?<sent>\d+)/o
                && exists $trafficDb->{$+{'domain'}};

            $trafficDb->{$+{'domain'}} += ( $+{'rcvd'}+$+{'sent'} );
        }

        $snapshotFH->close();
    } elsif ( $logFile !~ /\.1$/ && -f -s $logFile . '.1' ) {
        # The log file is empty. We need to check the last rotated log file
        # to extract traffic from possible unprocessed logs
        debug(
            'The %s log file is empty. Processing last rotated log file',
            $logFile
        );
        $self->getTraffic( $trafficDb, $logFile . '.1', $trafficIndexDb );
    } else {
        # There are no new logs found for processing
        debug( sprintf(
            'No new IMAP/POP3 logs found in %s file for processing', $logFile
        ));
    }
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize instance

 Return Servers::po::courier

=cut

sub _init
{
    my ( $self ) = @_;

    $self->{'restart'} = FAKSE;
    $self->{'forceMailboxesQuotaRecalc'} = FALSE;
    $self->{'execMode'} = ( defined $::execmode && $::execmode eq 'setup' )
        ? 'setup' : 'backend';
    $self->{'events'} = iMSCP::EventManager->getInstance();
    $self->{'mta'} = Servers::mta->factory();
    $self->{'cfgDir'} = "$::imscpConfig{'CONF_DIR'}/courier";
    $self->_mergeConfig() if -f "$self->{'cfgDir'}/courier.data.dist";
    tie %{ $self->{'config'} },
        'iMSCP::Config',
        fileName    => "$self->{'cfgDir'}/courier.data",
        readonly    => !( defined $::execmode && $::execmode eq 'setup' ),
        nodeferring => ( defined $::execmode && $::execmode eq 'setup' );
    $self;
}

=item _mergeConfig( )

 Merge distribution configuration with production configuration

 Die on failure

=cut

sub _mergeConfig
{
    my ( $self ) = @_;

    if ( -f "$self->{'cfgDir'}/courier.data" ) {
        tie my %newConfig, 'iMSCP::Config',
            fileName => "$self->{'cfgDir'}/courier.data.dist";
        tie my %oldConfig, 'iMSCP::Config',
            fileName => "$self->{'cfgDir'}/courier.data", readonly => TRUE;

        debug( 'Merging old configuration with new configuration...' );

        while ( my ( $key, $value ) = each( %oldConfig ) ) {
            next unless exists $newConfig{$key};
            $newConfig{$key} = $value;
        }

        %{ $self->{'oldConfig'} } = ( %oldConfig );

        untie( %newConfig );
        untie( %oldConfig );
    }

    iMSCP::File->new(
        filename => "$self->{'cfgDir'}/courier.data.dist"
    )->moveFile(
        "$self->{'cfgDir'}/courier.data"
    ) == 0 or die( getMessageByType(
        'error', { amount => 1, remove => TRUE }
    ) || 'Unknown error' );
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
