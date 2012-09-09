#!/usr/bin/perl
#line 2 "/usr/bin/par-archive"

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell
eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

package __par_pl;

# --- This script must not use any modules at compile time ---
# use strict;

#line 161

my ($par_temp, $progname, @tmpfile);
END { if ($ENV{PAR_CLEAN}) {
    require File::Temp;
    require File::Basename;
    require File::Spec;
    my $topdir = File::Basename::dirname($par_temp);
    outs(qq{Removing files in "$par_temp"});
    File::Find::finddepth(sub { ( -d ) ? rmdir : unlink }, $par_temp);
    rmdir $par_temp;
    # Don't remove topdir because this causes a race with other apps
    # that are trying to start.

    if (-d $par_temp && $^O ne 'MSWin32') {
        # Something went wrong unlinking the temporary directory.  This
        # typically happens on platforms that disallow unlinking shared
        # libraries and executables that are in use. Unlink with a background
        # shell command so the files are no longer in use by this process.
        # Don't do anything on Windows because our parent process will
        # take care of cleaning things up.

        my $tmp = new File::Temp(
            TEMPLATE => 'tmpXXXXX',
            DIR => File::Basename::dirname($topdir),
            SUFFIX => '.cmd',
            UNLINK => 0,
        );

        print $tmp "#!/bin/sh
x=1; while [ \$x -lt 10 ]; do
   rm -rf '$par_temp'
   if [ \! -d '$par_temp' ]; then
       break
   fi
   sleep 1
   x=`expr \$x + 1`
done
rm '" . $tmp->filename . "'
";
            chmod 0700,$tmp->filename;
        my $cmd = $tmp->filename . ' >/dev/null 2>&1 &';
        close $tmp;
        system($cmd);
        outs(qq(Spawned background process to perform cleanup: )
             . $tmp->filename);
    }
} }

BEGIN {
    Internals::PAR::BOOT() if defined &Internals::PAR::BOOT;

    eval {

_par_init_env();

if (exists $ENV{PAR_ARGV_0} and $ENV{PAR_ARGV_0} ) {
    @ARGV = map $ENV{"PAR_ARGV_$_"}, (1 .. $ENV{PAR_ARGC} - 1);
    $0 = $ENV{PAR_ARGV_0};
}
else {
    for (keys %ENV) {
        delete $ENV{$_} if /^PAR_ARGV_/;
    }
}

my $quiet = !$ENV{PAR_DEBUG};

# fix $progname if invoked from PATH
my %Config = (
    path_sep    => ($^O =~ /^MSWin/ ? ';' : ':'),
    _exe        => ($^O =~ /^(?:MSWin|OS2|cygwin)/ ? '.exe' : ''),
    _delim      => ($^O =~ /^MSWin|OS2/ ? '\\' : '/'),
);

_set_progname();
_set_par_temp();

# Magic string checking and extracting bundled modules {{{
my ($start_pos, $data_pos);
{
    local $SIG{__WARN__} = sub {};

    # Check file type, get start of data section {{{
    open _FH, '<', $progname or last;
    binmode(_FH);

    my $buf;
    seek _FH, -8, 2;
    read _FH, $buf, 8;
    last unless $buf eq "\nPAR.pm\n";

    seek _FH, -12, 2;
    read _FH, $buf, 4;
    seek _FH, -12 - unpack("N", $buf), 2;
    read _FH, $buf, 4;

    $data_pos = (tell _FH) - 4;
    # }}}

    # Extracting each file into memory {{{
    my %require_list;
    while ($buf eq "FILE") {
        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        my $fullname = $buf;
        outs(qq(Unpacking file "$fullname"...));
        my $crc = ( $fullname =~ s|^([a-f\d]{8})/|| ) ? $1 : undef;
        my ($basename, $ext) = ($buf =~ m|(?:.*/)?(.*)(\..*)|);

        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        if (defined($ext) and $ext !~ /\.(?:pm|pl|ix|al)$/i) {
            my ($out, $filename) = _tempfile($ext, $crc);
            if ($out) {
                binmode($out);
                print $out $buf;
                close $out;
                chmod 0755, $filename;
            }
            $PAR::Heavy::FullCache{$fullname} = $filename;
            $PAR::Heavy::FullCache{$filename} = $fullname;
        }
        elsif ( $fullname =~ m|^/?shlib/| and defined $ENV{PAR_TEMP} ) {
            # should be moved to _tempfile()
            my $filename = "$ENV{PAR_TEMP}/$basename$ext";
            outs("SHLIB: $filename\n");
            open my $out, '>', $filename or die $!;
            binmode($out);
            print $out $buf;
            close $out;
        }
        else {
            $require_list{$fullname} =
            $PAR::Heavy::ModuleCache{$fullname} = {
                buf => $buf,
                crc => $crc,
                name => $fullname,
            };
        }
        read _FH, $buf, 4;
    }
    # }}}

    local @INC = (sub {
        my ($self, $module) = @_;

        return if ref $module or !$module;

        my $filename = delete $require_list{$module} || do {
            my $key;
            foreach (keys %require_list) {
                next unless /\Q$module\E$/;
                $key = $_; last;
            }
            delete $require_list{$key} if defined($key);
        } or return;

        $INC{$module} = "/loader/$filename/$module";

        if ($ENV{PAR_CLEAN} and defined(&IO::File::new)) {
            my $fh = IO::File->new_tmpfile or die $!;
            binmode($fh);
            print $fh $filename->{buf};
            seek($fh, 0, 0);
            return $fh;
        }
        else {
            my ($out, $name) = _tempfile('.pm', $filename->{crc});
            if ($out) {
                binmode($out);
                print $out $filename->{buf};
                close $out;
            }
            open my $fh, '<', $name or die $!;
            binmode($fh);
            return $fh;
        }

        die "Bootstrapping failed: cannot find $module!\n";
    }, @INC);

    # Now load all bundled files {{{

    # initialize shared object processing
    require XSLoader;
    require PAR::Heavy;
    require Carp::Heavy;
    require Exporter::Heavy;
    PAR::Heavy::_init_dynaloader();

    # now let's try getting helper modules from within
    require IO::File;

    # load rest of the group in
    while (my $filename = (sort keys %require_list)[0]) {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        unless ($INC{$filename} or $filename =~ /BSDPAN/) {
            # require modules, do other executable files
            if ($filename =~ /\.pmc?$/i) {
                require $filename;
            }
            else {
                # Skip ActiveState's sitecustomize.pl file:
                do $filename unless $filename =~ /sitecustomize\.pl$/;
            }
        }
        delete $require_list{$filename};
    }

    # }}}

    last unless $buf eq "PK\003\004";
    $start_pos = (tell _FH) - 4;
}
# }}}

# Argument processing {{{
my @par_args;
my ($out, $bundle, $logfh, $cache_name);

delete $ENV{PAR_APP_REUSE}; # sanitize (REUSE may be a security problem)

$quiet = 0 unless $ENV{PAR_DEBUG};
# Don't swallow arguments for compiled executables without --par-options
if (!$start_pos or ($ARGV[0] eq '--par-options' && shift)) {
    my %dist_cmd = qw(
        p   blib_to_par
        i   install_par
        u   uninstall_par
        s   sign_par
        v   verify_par
    );

    # if the app is invoked as "appname --par-options --reuse PROGRAM @PROG_ARGV",
    # use the app to run the given perl code instead of anything from the
    # app itself (but still set up the normal app environment and @INC)
    if (@ARGV and $ARGV[0] eq '--reuse') {
        shift @ARGV;
        $ENV{PAR_APP_REUSE} = shift @ARGV;
    }
    else { # normal parl behaviour

        my @add_to_inc;
        while (@ARGV) {
            $ARGV[0] =~ /^-([AIMOBLbqpiusTv])(.*)/ or last;

            if ($1 eq 'I') {
                push @add_to_inc, $2;
            }
            elsif ($1 eq 'M') {
                eval "use $2";
            }
            elsif ($1 eq 'A') {
                unshift @par_args, $2;
            }
            elsif ($1 eq 'O') {
                $out = $2;
            }
            elsif ($1 eq 'b') {
                $bundle = 'site';
            }
            elsif ($1 eq 'B') {
                $bundle = 'all';
            }
            elsif ($1 eq 'q') {
                $quiet = 1;
            }
            elsif ($1 eq 'L') {
                open $logfh, ">>", $2 or die "XXX: Cannot open log: $!";
            }
            elsif ($1 eq 'T') {
                $cache_name = $2;
            }

            shift(@ARGV);

            if (my $cmd = $dist_cmd{$1}) {
                delete $ENV{'PAR_TEMP'};
                init_inc();
                require PAR::Dist;
                &{"PAR::Dist::$cmd"}() unless @ARGV;
                &{"PAR::Dist::$cmd"}($_) for @ARGV;
                exit;
            }
        }

        unshift @INC, @add_to_inc;
    }
}

# XXX -- add --par-debug support!

# }}}

# Output mode (-O) handling {{{
if ($out) {
    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require IO::File;
        require Archive::Zip;
    }

    my $par = shift(@ARGV);
    my $zip;


    if (defined $par) {
        open my $fh, '<', $par or die "Cannot find '$par': $!";
        binmode($fh);
        bless($fh, 'IO::File');

        $zip = Archive::Zip->new;
        ( $zip->readFromFileHandle($fh, $par) == Archive::Zip::AZ_OK() )
            or die "Read '$par' error: $!";
    }


    my %env = do {
        if ($zip and my $meta = $zip->contents('META.yml')) {
            $meta =~ s/.*^par:$//ms;
            $meta =~ s/^\S.*//ms;
            $meta =~ /^  ([^:]+): (.+)$/mg;
        }
    };

    # Open input and output files {{{
    local $/ = \4;

    if (defined $par) {
        open PAR, '<', $par or die "$!: $par";
        binmode(PAR);
        die "$par is not a PAR file" unless <PAR> eq "PK\003\004";
    }

    CreatePath($out) ;
    
    my $fh = IO::File->new(
        $out,
        IO::File::O_CREAT() | IO::File::O_WRONLY() | IO::File::O_TRUNC(),
        0777,
    ) or die $!;
    binmode($fh);

    $/ = (defined $data_pos) ? \$data_pos : undef;
    seek _FH, 0, 0;
    my $loader = scalar <_FH>;
    if (!$ENV{PAR_VERBATIM} and $loader =~ /^(?:#!|\@rem)/) {
        require PAR::Filter::PodStrip;
        PAR::Filter::PodStrip->new->apply(\$loader, $0)
    }
    foreach my $key (sort keys %env) {
        my $val = $env{$key} or next;
        $val = eval $val if $val =~ /^['"]/;
        my $magic = "__ENV_PAR_" . uc($key) . "__";
        my $set = "PAR_" . uc($key) . "=$val";
        $loader =~ s{$magic( +)}{
            $magic . $set . (' ' x (length($1) - length($set)))
        }eg;
    }
    $fh->print($loader);
    $/ = undef;
    # }}}

    # Write bundled modules {{{
    if ($bundle) {
        require PAR::Heavy;
        PAR::Heavy::_init_dynaloader();
        init_inc();

        require_modules();

        my @inc = sort {
            length($b) <=> length($a)
        } grep {
            !/BSDPAN/
        } grep {
            ($bundle ne 'site') or
            ($_ ne $Config::Config{archlibexp} and
             $_ ne $Config::Config{privlibexp});
        } @INC;

        # File exists test added to fix RT #41790:
        # Funny, non-existing entry in _<....auto/Compress/Raw/Zlib/autosplit.ix.
        # This is a band-aid fix with no deeper grasp of the issue.
        # Somebody please go through the pain of understanding what's happening,
        # I failed. -- Steffen
        my %files;
        /^_<(.+)$/ and -e $1 and $files{$1}++ for keys %::;
        $files{$_}++ for values %INC;

        my $lib_ext = $Config::Config{lib_ext};
        my %written;

        foreach (sort keys %files) {
            my ($name, $file);

            foreach my $dir (@inc) {
                if ($name = $PAR::Heavy::FullCache{$_}) {
                    $file = $_;
                    last;
                }
                elsif (/^(\Q$dir\E\/(.*[^Cc]))\Z/i) {
                    ($file, $name) = ($1, $2);
                    last;
                }
                elsif (m!^/loader/[^/]+/(.*[^Cc])\Z!) {
                    if (my $ref = $PAR::Heavy::ModuleCache{$1}) {
                        ($file, $name) = ($ref, $1);
                        last;
                    }
                    elsif (-f "$dir/$1") {
                        ($file, $name) = ("$dir/$1", $1);
                        last;
                    }
                }
            }

            next unless defined $name and not $written{$name}++;
            next if !ref($file) and $file =~ /\.\Q$lib_ext\E$/;
            outs( join "",
                qq(Packing "), ref $file ? $file->{name} : $file,
                qq("...)
            );

            my $content;
            if (ref($file)) {
                $content = $file->{buf};
            }
            else {
                open FILE, '<', $file or die "Can't open $file: $!";
                binmode(FILE);
                $content = <FILE>;
                close FILE;

                PAR::Filter::PodStrip->new->apply(\$content, $file)
                    if !$ENV{PAR_VERBATIM} and $name =~ /\.(?:pm|ix|al)$/i;

                PAR::Filter::PatchContent->new->apply(\$content, $file, $name);
            }

            outs(qq(Written as "$name"));
            $fh->print("FILE");
            $fh->print(pack('N', length($name) + 9));
            $fh->print(sprintf(
                "%08x/%s", Archive::Zip::computeCRC32($content), $name
            ));
            $fh->print(pack('N', length($content)));
            $fh->print($content);
        }
    }
    # }}}

    # Now write out the PAR and magic strings {{{
    $zip->writeToFileHandle($fh) if $zip;

    $cache_name = substr $cache_name, 0, 40;
    if (!$cache_name and my $mtime = (stat($out))[9]) {
        my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
            || eval { require Digest::SHA1; Digest::SHA1->new }
            || eval { require Digest::MD5; Digest::MD5->new };

        # Workaround for bug in Digest::SHA 5.38 and 5.39
        my $sha_version = eval { $Digest::SHA::VERSION } || 0;
        if ($sha_version eq '5.38' or $sha_version eq '5.39') {
            $ctx->addfile($out, "b") if ($ctx);
        }
        else {
            if ($ctx and open(my $fh, "<$out")) {
                binmode($fh);
                $ctx->addfile($fh);
                close($fh);
            }
        }

        $cache_name = $ctx ? $ctx->hexdigest : $mtime;
    }
    $cache_name .= "\0" x (41 - length $cache_name);
    $cache_name .= "CACHE";
    $fh->print($cache_name);
    $fh->print(pack('N', $fh->tell - length($loader)));
    $fh->print("\nPAR.pm\n");
    $fh->close;
    chmod 0755, $out;
    # }}}

    exit;
}
# }}}

# Prepare $progname into PAR file cache {{{
{
    last unless defined $start_pos;

    _fix_progname();

    # Now load the PAR file and put it into PAR::LibCache {{{
    require PAR;
    PAR::Heavy::_init_dynaloader();


    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require File::Find;
        require Archive::Zip;
    }
    my $zip = Archive::Zip->new;
    my $fh = IO::File->new;
    $fh->fdopen(fileno(_FH), 'r') or die "$!: $@";
    $zip->readFromFileHandle($fh, $progname) == Archive::Zip::AZ_OK() or die "$!: $@";

    push @PAR::LibCache, $zip;
    $PAR::LibCache{$progname} = $zip;

    $quiet = !$ENV{PAR_DEBUG};
    outs(qq(\$ENV{PAR_TEMP} = "$ENV{PAR_TEMP}"));

    if (defined $ENV{PAR_TEMP}) { # should be set at this point!
        foreach my $member ( $zip->members ) {
            next if $member->isDirectory;
            my $member_name = $member->fileName;
            next unless $member_name =~ m{
                ^
                /?shlib/
                (?:$Config::Config{version}/)?
                (?:$Config::Config{archname}/)?
                ([^/]+)
                $
            }x;
            my $extract_name = $1;
            my $dest_name = File::Spec->catfile($ENV{PAR_TEMP}, $extract_name);
            if (-f $dest_name && -s _ == $member->uncompressedSize()) {
                outs(qq(Skipping "$member_name" since it already exists at "$dest_name"));
            } else {
                outs(qq(Extracting "$member_name" to "$dest_name"));
                $member->extractToFileNamed($dest_name);
                chmod(0555, $dest_name) if $^O eq "hpux";
            }
        }
    }
    # }}}
}
# }}}

# If there's no main.pl to run, show usage {{{
unless ($PAR::LibCache{$progname}) {
    die << "." unless @ARGV;
Usage: $0 [ -Alib.par ] [ -Idir ] [ -Mmodule ] [ src.par ] [ program.pl ]
       $0 [ -B|-b ] [-Ooutfile] src.par
.
    $ENV{PAR_PROGNAME} = $progname = $0 = shift(@ARGV);
}
# }}}

sub CreatePath {
    my ($name) = @_;
    
    require File::Basename;
    my ($basename, $path, $ext) = File::Basename::fileparse($name, ('\..*'));
    
    require File::Path;
    
    File::Path::mkpath($path) unless(-e $path); # mkpath dies with error
}

sub require_modules {
    #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';

    require lib;
    require DynaLoader;
    require integer;
    require strict;
    require warnings;
    require vars;
    require Carp;
    require Carp::Heavy;
    require Errno;
    require Exporter::Heavy;
    require Exporter;
    require Fcntl;
    require File::Temp;
    require File::Spec;
    require XSLoader;
    require Config;
    require IO::Handle;
    require IO::File;
    require Compress::Zlib;
    require Archive::Zip;
    require PAR;
    require PAR::Heavy;
    require PAR::Dist;
    require PAR::Filter::PodStrip;
    require PAR::Filter::PatchContent;
    require attributes;
    eval { require Cwd };
    eval { require Win32 };
    eval { require Scalar::Util };
    eval { require Archive::Unzip::Burst };
    eval { require Tie::Hash::NamedCapture };
    eval { require PerlIO; require PerlIO::scalar };
}

# The C version of this code appears in myldr/mktmpdir.c
# This code also lives in PAR::SetupTemp as set_par_temp_env!
sub _set_par_temp {
    if (defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/) {
        $par_temp = $1;
        return;
    }

    foreach my $path (
        (map $ENV{$_}, qw( PAR_TMPDIR TMPDIR TEMPDIR TEMP TMP )),
        qw( C:\\TEMP /tmp . )
    ) {
        next unless defined $path and -d $path and -w $path;
        my $username;
        my $pwuid;
        # does not work everywhere:
        eval {($pwuid) = getpwuid($>) if defined $>;};

        if ( defined(&Win32::LoginName) ) {
            $username = &Win32::LoginName;
        }
        elsif (defined $pwuid) {
            $username = $pwuid;
        }
        else {
            $username = $ENV{USERNAME} || $ENV{USER} || 'SYSTEM';
        }
        $username =~ s/\W/_/g;

        my $stmpdir = "$path$Config{_delim}par-$username";
        mkdir $stmpdir, 0755;
        if (!$ENV{PAR_CLEAN} and my $mtime = (stat($progname))[9]) {
            open (my $fh, "<". $progname);
            seek $fh, -18, 2;
            sysread $fh, my $buf, 6;
            if ($buf eq "\0CACHE") {
                seek $fh, -58, 2;
                sysread $fh, $buf, 41;
                $buf =~ s/\0//g;
                $stmpdir .= "$Config{_delim}cache-" . $buf;
            }
            else {
                my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
                    || eval { require Digest::SHA1; Digest::SHA1->new }
                    || eval { require Digest::MD5; Digest::MD5->new };

                # Workaround for bug in Digest::SHA 5.38 and 5.39
                my $sha_version = eval { $Digest::SHA::VERSION } || 0;
                if ($sha_version eq '5.38' or $sha_version eq '5.39') {
                    $ctx->addfile($progname, "b") if ($ctx);
                }
                else {
                    if ($ctx and open(my $fh, "<$progname")) {
                        binmode($fh);
                        $ctx->addfile($fh);
                        close($fh);
                    }
                }

                $stmpdir .= "$Config{_delim}cache-" . ( $ctx ? $ctx->hexdigest : $mtime );
            }
            close($fh);
        }
        else {
            $ENV{PAR_CLEAN} = 1;
            $stmpdir .= "$Config{_delim}temp-$$";
        }

        $ENV{PAR_TEMP} = $stmpdir;
        mkdir $stmpdir, 0755;
        last;
    }

    $par_temp = $1 if $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/;
}

sub _tempfile {
    my ($ext, $crc) = @_;
    my ($fh, $filename);

    $filename = "$par_temp/$crc$ext";

    if ($ENV{PAR_CLEAN}) {
        unlink $filename if -e $filename;
        push @tmpfile, $filename;
    }
    else {
        return (undef, $filename) if (-r $filename);
    }

    open $fh, '>', $filename or die $!;
    binmode($fh);
    return($fh, $filename);
}

# same code lives in PAR::SetupProgname::set_progname
sub _set_progname {
    if (defined $ENV{PAR_PROGNAME} and $ENV{PAR_PROGNAME} =~ /(.+)/) {
        $progname = $1;
    }

    $progname ||= $0;

    if ($ENV{PAR_TEMP} and index($progname, $ENV{PAR_TEMP}) >= 0) {
        $progname = substr($progname, rindex($progname, $Config{_delim}) + 1);
    }

    if (!$ENV{PAR_PROGNAME} or index($progname, $Config{_delim}) >= 0) {
        if (open my $fh, '<', $progname) {
            return if -s $fh;
        }
        if (-s "$progname$Config{_exe}") {
            $progname .= $Config{_exe};
            return;
        }
    }

    foreach my $dir (split /\Q$Config{path_sep}\E/, $ENV{PATH}) {
        next if exists $ENV{PAR_TEMP} and $dir eq $ENV{PAR_TEMP};
        $dir =~ s/\Q$Config{_delim}\E$//;
        (($progname = "$dir$Config{_delim}$progname$Config{_exe}"), last)
            if -s "$dir$Config{_delim}$progname$Config{_exe}";
        (($progname = "$dir$Config{_delim}$progname"), last)
            if -s "$dir$Config{_delim}$progname";
    }
}

sub _fix_progname {
    $0 = $progname ||= $ENV{PAR_PROGNAME};
    if (index($progname, $Config{_delim}) < 0) {
        $progname = ".$Config{_delim}$progname";
    }

    # XXX - hack to make PWD work
    my $pwd = (defined &Cwd::getcwd) ? Cwd::getcwd()
                : ((defined &Win32::GetCwd) ? Win32::GetCwd() : `pwd`);
    chomp($pwd);
    $progname =~ s/^(?=\.\.?\Q$Config{_delim}\E)/$pwd$Config{_delim}/;

    $ENV{PAR_PROGNAME} = $progname;
}

sub _par_init_env {
    if ( $ENV{PAR_INITIALIZED}++ == 1 ) {
        return;
    } else {
        $ENV{PAR_INITIALIZED} = 2;
    }

    for (qw( SPAWNED TEMP CLEAN DEBUG CACHE PROGNAME ARGC ARGV_0 ) ) {
        delete $ENV{'PAR_'.$_};
    }
    for (qw/ TMPDIR TEMP CLEAN DEBUG /) {
        $ENV{'PAR_'.$_} = $ENV{'PAR_GLOBAL_'.$_} if exists $ENV{'PAR_GLOBAL_'.$_};
    }

    my $par_clean = "__ENV_PAR_CLEAN__               ";

    if ($ENV{PAR_TEMP}) {
        delete $ENV{PAR_CLEAN};
    }
    elsif (!exists $ENV{PAR_GLOBAL_CLEAN}) {
        my $value = substr($par_clean, 12 + length("CLEAN"));
        $ENV{PAR_CLEAN} = $1 if $value =~ /^PAR_CLEAN=(\S+)/;
    }
}

sub outs {
    return if $quiet;
    if ($logfh) {
        print $logfh "@_\n";
    }
    else {
        print "@_\n";
    }
}

sub init_inc {
    require Config;
    push @INC, grep defined, map $Config::Config{$_}, qw(
        archlibexp privlibexp sitearchexp sitelibexp
        vendorarchexp vendorlibexp
    );
}

########################################################################
# The main package for script execution

package main;

require PAR;
unshift @INC, \&PAR::find_par;
PAR->import(@par_args);

die qq(par.pl: Can't open perl script "$progname": No such file or directory\n)
    unless -e $progname;

do $progname;
CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
die $@ if $@;

};

$::__ERROR = $@ if $@;
}

CORE::exit($1) if ($::__ERROR =~/^_TK_EXIT_\((\d+)\)/);
die $::__ERROR if $::__ERROR;

1;

#line 1014

__END__
PK    -�A�/jJ�  q  	   SIGNATURE}W�rG}�W̦j+�U6���j�U�-�J,[6mٕ�-t7Z���p9$m�a�}�H��HJ�������p��8m���3nr�XS��9�=]rS�K��}�Նf���f��k.M�hΎޞ�:�||2����m[j�Snκ������i�Yq3�����o�E#�.�G���p���k��|^����T�I�6mְx��W����7� ��6͔�<zxbX�a.O\��|85����KZ�6O������"�<�|�0��u�?��X��]�4�7_�:���~Ώ�hK���qӜ��g����ݸ�/�~�[�g�~hԢ[�-g�����8�d����:�&1"��|���m?�D�r}?�6�2W�E�"Sg�g`|���V��M;+������'�o���frz���esv<��_�8zM�����>����A��
��5����6��MG�W����^�d�/�+-�9)|bT��ɇ,2)���_����l�Z��c�TT������\qS
Μ�f��w{���6O��M�RU%b��A.*\JL)�LR����_۟�/����6�HZ�$,iS�a�,�b�
�\�P(n�20(@2T�L��o���.�ĉBA��LAr2>�l�>�BP%O�1�-yq��wY�(:��TWre�[�p�%(�D��H�>�96��ݷ;�Rtȵ����QP|S�,
59'c8�t���٧�3�fW �*J�
,��X5��5;�:��>ȧ�7{��g�&��	��7���qP4� ���+��U�L�P@��
M��^ ��ZB�N>���
_x�����K1ɜ�D847�\e���l��җ���
��
�� �b2�ј�7�3����ƦfPNH�g1��G�;d�E�f��)���%,V7g_Ţڮ���[
0������@*>�J����r��f����Η�jݏ��}�4�f�.�ς>��r�x2�a;�qv�����B0�����5)+v>�,�G'�����w��e��PT�k���ڂ��� ldxȫv�>h�[�m����) �Ra.cq@�E�
%�h����%)S���SҦ�Y�dɕd��W�L�^�=߲gW��B�I���Lk�s��FD�଍1����u�����De�s  ����)�Z��6�_]���m�V%ע�8�6�q��0r I̔�g[����/T�B��M+��MA������2f+'�y"�NgL/���1�7�K���I�!w�Iϟ��z�$��l���Mrj=WG��4q#U��7��?
A�Ù��ކb9�Lu�OSW�`�ޡ��LL�:�8'��M�$8�i�H�k�rQ�#{8tu<c�[[�|Q0�t�#��_��+ix3�Ϫ`$�=e{yv|���և�����\*�=�ZUt��-k�*�
�f�����u�O���ՔB��a�p�a����=),`�f}�lx��|��o�!����I^zF�Y���
S������+��N�ޛ�[Q%ߦ�%L�U�n�g��w{}4o[�n&��{�f��	>�Z�>���l ���+v��
)�2ځdJl�!�l��(��rH�p�%�K��5�<���N$|s4@�Y�D:e�L���,Ƴ�,g2ʰ(㌯O@ʋjG�,A\U%��E��#Aȑ�"�q:��3�h����+bB�f�+���
[���,�o�cƷ�	M�s���4�I*<�3��mʬm0(��d�Z=����l�0�l6��=�����8A�2��Hĝ��N�ƹ���t`�-gn`4��`��K�v5u|,V�b� `1f��獙Y�0�L��?�x���ўј׌�]�5]����A�2�o�Rʮ̌�Oіn� ����tm��v���m�mx����O=J����o|�	!۸JW�w���z��ޏ�V�C�,������%��V�+owOϱ��L����~hY��1q����<w�.�-��t;\�QW7�����6B�(�X�7��t�T��?����K��!G��
��y1��m�7�X-Y������n2(4�KE��5\�{�]7]��c��v�hk�vb�4�m衟�kba�=
LGr���C�߱�����"ņ�������50,�4�D|i�oh�87��7�&��I�h�8Z�8�2�ƍ�	�h�8�2��G�єq4n�G�Ѹq4a�G��Ѹq42�&��)�h�8�4�ƍ�	�h�8�0�&��I�l�d�>r�#��������'0�����hdw�å�H�u��b�aXs]M?u̮��dt�#"[k�v���{Fװ-�6�ԧm�Ɠ�#�qL�Mu�h��)��Un
(�%y)dl��4�*`��M� Ed����0݁_�@o�ۑ�v��k�Q��޵�/���)xŨg�\C�N۱�%Vo�ň3pGf�Fet�b8�$��߈H�*�TT���z�z?=l�����c�:'D����DC���D���`U�\�d��FV���.�x�o
��g��s��C� Q�g�p��V��
'�lx�Z� �n0{�P��9��SL��v���X�gv�TB�Pxڲ��yE�`1�f��LT�֛V�]0�[�O���~�'3�:��>҈�L���Ё
��a�ɶK���u�kxC�8`�t��zC&�j�CUZ8�rF�� �j0e�O#vp�Z��+����űw���p��P�3��^�Oo'�U�`�I�W6���Mo�`��l ��c�M�0���~e#{�@�U[o5�y=�� n�/b�A��ʆ�-���̟�RVPKML�@F�p_o����a�|d�,�5��Y�Ǒwͪ�Ļ��ГH^��q%��� %7�*�ۙ�$�o��ǟU �Oﯛ��-͕Ӣ<a3����OJ���m�/!l��F2��(�4����|Q�Z���4k@e^K���aZ+�iu����*������_`1:�@�y�>�q��sv[��n�i0�10��Y�M�Y���,˞�O���\�|�:��7��6�{�vd�F
�Oȼ�D�2	r�
�
7Y{Y�������[t���zN��Y�'gk}��<5���0�ǹ�%��k@M��2��e�=�g���K��D1)��+���H�XZ�>I���d��$ڝ���t\��JC���m�WW�ߡ�P�$���
C�&�8Vc��}���[������h���F��z��4y
!tO�,�%����M�I��B�ȍE
0����	���CD����w�'��;Tq��Ӯ�=�O�ו"+�縸��R�z�e5z�J4O~������j�t���]t�>� �=F����#W6��A*]�m��;uܩ�z��֡�%��q
�ν�8�9�^|��ʲ���'r���#�A`�j5�*��仁�lO���I�tY�R/�n�m���c_��[�!�|"�J��S_m����M�=@�Z r�r�S�7�l��p����o�j�NŹ^d��J����-��Fih��M���� D��=!d9A!����5��9T�\:*h�Ɖ�f+vP��
�w�[̨p�f�,�M���o�{Xہe�cͧ0iq<�bB0[�r�\������z�4�ⷞC�+�%����$d�{�z��צ�H�X�{�?&k��7]!�$-k,ʛ\�ޜ��N��F�h\��O<�f-�K��?�w�]�?5�tu��H��?�ⵂM	b�؅a�LW[=�%�*F*,�]s��x�E~Qx?�B��ᶒ������T��?�s;��u��+*��o[�r'r����u"'��cN:,G���!
.gr��R�͞������76{��%��8�4�JѸ�n�K�?�?r�w�*�L��?(6���S�9V��:튆z.���Dv�ٯ�PK    -�A�_`�#  '     lib/POSIX.pm�Tms�8�~�q\�p��Ob2ŵ
q�R*f�.d��S7q�Ş��].�.�̋Z���
4q�gG�^�s�Dу6�o��2�΃m�BĖs�X1�
�|�e���ڃ,�H������X����,��@�?����:��$���<��pu5�AJB�2��I�Gٲ�<�=?�3�G��t����.��.�8�$���<��W�K+B���enL��m��ɇ:V�d���J��6����a�-��Ղrm�u�1�(T+bB�����X��Qe�=��M�Օ+ʶw�wD�d���s��kd��o�n����~�������\\��٘�yE�Y���c���@���~�uYY�}���r��}1���������X�6����yFH�m�����	�&�ۘ��-�e)!w\���G^	5�,�y��K�NI|gz
���i�h�l[��\��O^�'I�
��4�ܨL�{'� -�^5*�z/{�Sq�0b��O��9��PK    -�A�g�J�    
�~�֨�k��w�:L������`�P8V-Z{W(`�@$�B��F�V\���9�ټ���$ؕa�9
N!��t��{��ZƜT~*��G8tA�"�M��'��H1�Ո�*��-���	������,�d�p]��B#[�b�'�2���"l�(Z)=S� ��5�;��$4Z�����5y�!
��ȟ��(�#��ny�f�s��c!��1��!KC�6ͷ�5R�M�sC��Ņ#��`J@&� ��� ��Љ?qRie(�	��W�����h��1{���^-իY*�����}�d1^,��E�-�-l�G��]nKR��G� ��9�bГd�N
�-Ui���Q���d���mk�]
]�Yfޠ�e�}�~�},J*���7oՙ�u�����)V�.��L7'�U�F�V2u�� ��B��5�
}�7m��_��{����Ut��%��E\B��m�������|�ؔ��q�0N�_,H��*�
��q�yD��"�K>����g��'����]�7��H+�X(>՘+~�sA�7^�9FI�M��v{���]�bY`�φG��6���RL,�ln��60��LF0�k�0�4%��i�4)��f0�
��I�N��û�A�i��H�`g�-%�WJ*vΦ�搰K��4O�;��3rX�N�d L��2s��ɰ���=@�6.%�u��A���J$�W6���!`|@����� CD�U*�ճ�Y3�avص�%�.9d�ͼ+�*x�:��������(di'*�0���^x�҃�����a��=7x�d���
�9����QE~1Ձ=_VX�~��ʋ�3�%٢�z���۰���)��4�Pm=T�S�z.�f����
>!m뜜��Y<��}:J/��s�%4-͍\�8~��c]�����������W�nUD���x]�3G�@*�(�*J�u��*}5��>0�1����ʴ�n!�\C��6���\��l|�詫�Sf�
�2M�4���hA��V���mX7Rn�����w�`؂���J�IR:r�i�G��ng���;Sl`=J��:��n����OW���:-�Uڎ�vԞ
�0]��W�R�~L����"x�#x�A�w	�{��b��)1R���EY�ѱ�}�˻X����j����fX��Vi��
1b�c!Ǟ�J��O�y�-�^E_=��t���м��~b�~��^|�����T��/"/���n�� �����ЮAqk�����iUK�<����G"y�@(�m��3�jo�
� ��FO��U��F��h�c�(᷶c�;��%گ`Y�
��_\�}�s+�`�y-ߒ�	�8N�WQ��N�U�}Ӓ��5�Bq���$�PPb�P�FV�$�rF�ˡ���lٶ���=����P�ߦM5�v�B��d���5��,#�Y=])�{�j�]\RZ�ȌC��2͍ˢ%殬d���}�9[�Yc.J�X�1�KF�б���䩷�i�o�5u��$���R�����\�;Oʚ�L̲���5���T
�}-�V�mZ|(�͆rC��#�YL�%�K�-.��2�5ԟ���j����o��?-�����_����O1_.�Ae&�w
�o��������f0���k��[�;��S�{�/�p|G�������x�hܮ��q�^	�l�N�o�$���{5|S�{|��Ѹ����]��"�������w|Q\y�v|Gj��υl?ô�.��6-f��;���G!�QŇ�����K�C��������C��R�9H=6�~o<�����W�wķ�e>�ځ:[ޛ;>�����d-�?���Ĵ���ʺ)D�Δ�,>���ǒƍK+������>�ކ'�^��rS�g�;֜k�yW����r�o~r���v���'��Gg��M��e�ˍa�I��c�?�����~����ߐ���7h��I��n��N�cv/~���~lC�h�M�K�g'��c�>nJ�g�68�*A��L��aO9�K�g����_j��{8�	��+����	�kJ�t���I��	ډ��>�I�z�%��&���6x~W�v�'�L����_�3�,��	�sY��|%��B\�˵��h_� I�z��@n�	����ޑ@�O%�?1��&$ȏk�k��j��<A{Z�w$c��w��>-���uNg����K`��T��'��������L?y+��#�������<y.�E��3}}Y��=.�N�F�� ��_�ٜ����zŤ�b���=NNI�ӈ��c�G�o�>'Jx�p�=ʾL��NN?O��v���W�l�{�s����9�'����w���p� >èަ��~��kee76��*�eeZY]C]@+��@+��ʪ���ֵ������
0�--�s�P��{=9�e�'�<�h<�<iJt�����yx����R��c�B�����4�?I�AZ3�S7w������m�Ot��n�*i�/�[�^��f�Rp�k|��<ܨ����*�l�
�F�R_Ex���&|�������}
����T�̈́[��wnW��	�V�Ä�ܼ���
~1�m
n'|���@�z��<��>�~Z��$��`<^Cx���C�C� |���$�I�'|���%|��?C�F�_��*�v�
��
>�����_Jx��_M�R���n�N�:�'�G�	ߧॄ�T�:�-?��"ܮ�+	�V��S�g	�U�ަ�o�F��^�?#|���'�O��.��iE��-���� ܡ����S�l<��U
^H�Z�K�F���^_B���	ז��O�����T��	�|��
��K�»�����=
�����'|H-?��S�+�h³�*�}
>��Z�Bx����F�	_��s	ߥ���)x#��~�m��x���p�����y
��M
���U
���
�6����^��pC���u��F�)�ńg*�U��
�Ax��O!|��;	�V���)�|�{���}
�H�I��pKg<��p��5<�Vp�B���ħV��%�M�7�F���^�_#|���#�O�?&���'ܶ"?Cx��[�x�P�ф�S�7)�
�G*�&»|;�����(�;��S���T�c�[V�����<�f+x
�>Cx���%|����x�^�'P��"�W��ާไ�T�k�x��p���A�]���T�ń;�^!7�1��
$�I�#�M��ޭ�k���i��+�
�+�sB�
�����o�W�W�����W������W��<"���f�+��Z���»���*x���Kx���	�U�;	�S�*�O*�"µP< ܦ�nW��3�Q�
�$�>J�_���W���W��+��B�
�7!�#���
�+�!7���������WB�
�W���T����P�1���j���|*�m
�Kx����V�+_����Q�e��*�
�<��?N�I��ZW<��6�p��� ���+���{,t�<ğ��'[�gH�CI�.�?�p��ϖ�yn��r	/��Z	/��&	�I�R	wHx��{$|��_)��>S��Hx�����	_'���^�gI�F	�.�=>Q�wI�d	�p]��Ix��k��g����'I�M��g��$\~��.��s�~��gJ�E³%|��;$\~�M�p�YE����Γ�T	/�p���J���$���K%|���I�h	_%�c$�[�/��5~�����4	_'����%�r	�(�WHx��W�wI�U�+�c%|���%�O¯�pC���XNJ��~Z��%\{,���`��_'�6	�^��$<C��>^�3$|��gJ���c���(�	�$Ẅˏ��$<S��Ix���K��^+��s�M>EJ�T	o�p���U.��n	�U��H�4	_+�ߗp����0	#�,/��g�O��Zd���u�bH�b�p_>�~�4�h�e�}H���0�it�����it�ᵌ^�4��p7��4��p����f��=it��rF� �Sp���iH�+;=it��LFO@]_���k�F��1�r��Յ5F_�4�����HG����h3���3�LЗ��3�s�G��3�(ңY�}�1���~�KY����X���4�FoE�;���ތ������W��3�?�����ѿA������9�W��3z5�cY��A�'H�Y��c��f�g�}H_����f��e�g��H���3z��X��C��c�gt1�׳�3z&�����Az<�?��!=���ѓ������������k�����ї#=���ї }��9��3Y�mF:����g�z2�?�?G�f�FE���q��!/�a��Ξ�9��^���]Cz���5c+����z��~:�^�/C��T��;#}8>!��x��R�-����V}���^=�C���VV~L+����m3�C9��z�}ƽ�,��)zh�4�������sǐL L_�\��Iֱ�?f�΃b��и�ԸQ�О� �H��� \�twC�Hs3z=�M	$�x,O�Sbsg��3��L΍(�Ml]~j�=�r`���#-�T=䰁3n��e�X����S�
�gB_���z(�vʑ�E@7���7x����\�d��g"YB	c��TɔWad0^G�_�p���
�^y�p���4>�n[�2��d~�����?�e��3(Z0�Z;v�bL؇킾]��mC-�A_�Pn��
,��Wu���d��i�=:�:�x�睥Ni���|~U�m�C7U��q�xGz6�Y=z�Yo?��҃�gnZ�<�ޕ�U�E��q�nk7L���֕0�y*����[�����w���!����s&4��#f�3�?o���q+#��vHN�|fkG+L��P^d�g��6�l`�vOp������~��
>�nwgE֙��'v:�䓭o����
����Ӎk���gp��=<�ޮ�7�5]d}���������Z��A��ڹCcݴ���-������Um�t�p��w�v�6�f�O���@o���	 ���Y;o�.A�-Lx]�}6OD�0�g�~s
S��s=2[�
?�
�7� ~�t{������<PxU��s� 8��NEY$!o���S���_!�����[r8�a׌'&�84Z����� ߍZ PM7��Yt14��#�W��]:�؝z�4�Xp��N|�[�|Eo?��ݡ��q`��h�֎G���������g�fW2��MN�J6n�ѥ$i�'��_1I���@m�M�f\���Nғі�L9n�s�mz�tw0

�ل.�_-ǿ��v�� k����c�h�������[;vB�����l���^��Z��agƞ��=��lոߘ�:#��'-��q	˖`����l���J�8͢]��p�g���~���V��	�Hn��Y]�'f�{�5^��dZD�I%�d�Q34;삔��LYx.�o����d0�:�$���;�y�>g�"�������Ƣ&f7��a���Һ���}|/�M�C�f�j3�¨�\�YlT��̵>��
n�������(ރۮ���Ah���(.���%�V+�=���i/�n��\?46�
/��g�܁��튫`��l�;@O��݌/�F`���1V�6:{O�?4NA#<����L�x�����0�Ab���3�`�-� ��o?[?/E����N�� ���6�!�q�1����Z;@�S��k� m��T~<3tˁ�]Ŵ�ڨ���X��;L9���|a�v���v��I�M��1����������Z>�q��s�7�m?�A��xQX�W�y�%�`{ ��Эz��䮕���ϟz������� .���{lЬ.X��6�V�n�Go'	w���F�'�ii�1y�����?��AP-M�������wd�V �7�[[�AS;z�L((��S�}�M�Xޏ o�h��������%��꫙E�_��9
}7؀1.̔?��Y|�t�1�j6n]G�������׍�Pzt
�a��
���9ۦ�k�~\���;e�֙ű��V���b�
�O#��O���S#��~_�M���{�,�&ǜt�o4��4d�d+�I0��;ϓ�L���y���UHЛ>��� � &Y=4E��۵�u~ˁ$}�k�=���Gf�a%a{Cw[;n�@�P�r����	a��r����|"������"֟nug}ܱ'p]�6P��!hOn� Tm�Jو�Z]}ΐCp�N�J%Nǁ�8��.�	����ak�rn�H���)���B&p��\�{i�w�k��|8��.o���O��.��ģ�?
�"�#�$�Kbh�Q<����ݓ�VW��t~l�x�׾��:6���Ag��a�X����b�9��o)@#cE������Ƶh ���d�'����u�|�
v��ǹq(��~'�Q�:mٙ��̌Շ8���K�se���¥�T:K�<�JO�yY<�KX�R(���֓�bg���C��J:7���j �����=|�P�1c�`���%>�m�#���v|��>�g�lɗ��m�Av<.:=���Ǆ� �X���Ƃ�~�z茷�X�@fu�o�V%���$�4���X��Y��`!�%��JI�v.�����|xy��;0Qh���Ƴʙ�����Y��l���1[�3��1>�>��0������=��{�9a��ds>c�����臟��_���W�ݐֿ
�ㅋ�y�J�ma��ev��TnG?}���j��#�Ӈ �_{�7�c���Q�*|�O�'�=Y�+�u%u��9�;�
���`���a��=�G���uX��a|[ѿ-90�KmZ�k��㋟a���c�a�6g�Yܕ����c혐�i�GM�{�s`�pK�}Դ/��,fޙ�ɇ?]G_��C�0��Y��ґ�w�<��6,���	�kAKm��tJ4��1>�Tʞ�^b���l����yOp���E��i���R�z�������k�ܡs�Ec̥|ޑ���pID�_0�8��J槝����SU=��v�f�1�b�3����{�#��q���������ym��8�*!��C���0"���sx��:/�uq��8��
@��y�H�@^3�����x�����2�q�@�C��=�|��Eo~��
�.Wq��p��z��|9��Y�.,*t�xN1ԓ�,�0U*85�$5qiLa�۟q��S���u���YH�ܹ�	�<��h�垏A�s�E�~7FJ
��z������ؼ�S4��[�[T���g�׋A�z�qF��7�A�Y��?gI�'���xi����ﺹ�Y����z�%�VXZ�.���E �Y�.�����au̹� ��Լ<g��;���NO!��8]y^g~	#�/E�Y�\N�������<�/ʝ��#b~��]�y��0z|XuY�� �]\�{|����|
���=��^��z�4�2O^<�����Hs�%-v��2/v�cd4�/�+>g��66�� �K��2��$�h����h��"_�����!�����rs���J��\E���N���b�.u����İ�-��eDq	/Q2�'��KsY��}z�\�����=&����#��I�g�|�Ey�9'�J��'�E_t,�h,��X����c�'Ƣ��E�E_t,��X,�-(�-v�܅~��[�h���]�w�4�U�6�;�R�EH�{������b�����-B�T���=�-)�!�J@S�����u��Q��w��+�������)��%�Xz
y���E @K��v��^�@x=���XQQ��H�S@����]���r��/Ν�S�G1� ���(�"w�	��[�젣�s�8YR��8A,�	�QN�Y�s}��w>���q{��Y<W9��y\^w�(���F��B?����(��dw���Ť�����s�h	x
�Xdv�'wN-�z�Qº��#A+�a{���e�+cNAD�L�hTф܂X.`�����R?X�z.乱1�=R�\�.g�HqѼ��ҋ=�:�8���@����	.Ww��\�����$�׃�;���q��G|��8�|�)�E�%Ex�rY�J-�aurƅ� v�\�+e����1��NE:(�OEQ����q�b~g>	���-"�W��I��P��j�',�2+-��s=�̯�b��%���	����|1����|$9���/*9_Lr>.9I��%�#����|\r>&9��/*9���$��c���;��}%���={��W���n>>��C�A���㠙���'����W��+\�i���;�O,�D+*�W�s�
a�G�,wU4��i��]�	M3]���mwO��H�}�D,&M[��80����o���>�e���;���H���D�=�o�H7���j$�¶�"|�S��#�l���D�!�|#�{�z�F"����� _��� |0�| ��Dz!��(�{�C{04"�6���^�4��_���5�R�銔�,�&����o�f^��j�KM�iq��M���ߟps:{��-�k���H�9v�j[a����'�Rf���4@��׈�h<o{7��2����+�<�ܕ�ٛ�hj�g8Y��d������ ���lO^��M�?l6τ\:�L
�6Ŀ�@����I�=j�IM{$ɝj�J�I�xx�35s�Pgjv�E��m#�Λ��f�L��I�C^(���k�^� ��H��Y������f�ߊ�)�7 ��`���;���ØE�3�ޞ���KJ���NV�q�����!�*�v����v?��V$C�ڇ�L�1%uC�'c������
�׀M�;�ԛi����ڛ�9^�D*�wd\{�XX��Pn��H��A˕'�nX!�1�����;�f�]1dN��+�|t�3����o#���D��O�6%�Tyx�<އr�`�r��e��Dؾ�`7'{a���
�˔��zmJ{L�R�/>�>"]ܣ#�-h��i%�h��GG�D��y
��T�8(��D��G��D��G��=:�]��^��"Aܣ#�!�#��������T��=:B^�.���%8"��|�^�����(�Y�P��T���Ǖ�|M�Z��W��{t��$��{t�;"�;	�=:����S��wo�{t���)�B�/ޅ(�ѱ-ޝ(������=:B¾�=:B���>����N
\س�GG�S��=:�����{���9�q�3�����J~�U�/�7��6
)r�����qP(���j�Pܣ}W���_�_�
5?U��槆f�8)^ܣ#�#U�G':W�"�=:�_���
>��jf���(\��}��Na��a��ޞWpao;��y�
;��~	��{t���=�{tT��Q^���zm�{tT��mqώ���_G�YJ;�)t���ҎR%���U
��J��U��X�T�=���Q��*�O+���F������mW�_U�۫���j��
���?��G�G#�{h�]��gD���Q�%��gF��U�����>џ*�^��(�J~qO���J��J{�R�=����~Q��������GIWI?���a/'�����E�tqO��O��"�Ž,�_��X?q�诸E؇�wE��}+B�
�EJ�2��
������������ҿ��^Q���?�=��.�M�|-U<w&���źN�O�O�=�W*��o����:a3����PC��FC���H�ЫX����A�~����u���.�7!O�ner�����]�h!דDgR��D���G���}>�g	��

���n�p�oQx��~
�f��R
��p*�yΡ���%���I
�@�
wP���)�ph�O�uN�0��9�P���>I�(�@�
ߢ�0���L�Sx�S)̣p�5.�p�OR�
7P(�Y�&�Զ��I
�H����6����
�����9����ĳ�x12]��h��yz/�]5�;1抯Wߚk���(�fR�"^\]	�7MZ��^��o����B��c��p����)��}�ҳP��yq<�j���s�&��"������W�|�5U��S����:��cU�5��RmKV�a��N�~�=3��<�|;�f��tݔ ��-'��"���R�l���+C�#3��f9��>�n�9ь)�P���m \��&�7
P�g:  �k�8�N;A��`=�p������::p�"I��-P��M���`�<0�!����g�'�`�J�q��u�v*
��	m��Tn��xMڪ�0�C���#��33�9N��T�į���Y.�ڋm|�P|)k�=�����J�n�ݛ����ʓ��^�>�����yrC0���0�؁��af7p��b��)�у#5��!�}g��q�0��O�����' N��t��;
RZ3ˡPlʹ	��6�ڠ�9R)B��/S�`zv���ۍ���_�oA(s~��	�;����/Ҝ-1� a N vJ5ܐO���"��|�j0��lI���	��2����=6���O�B�|��)ۊL�g�f<z�T2���q֤�Iq�fe�mA����1Y��!n�y{�
J�P`GI�ևlC��BF�ڎ�CUć������(�-<F�F^�C(�-��B$y���&��R�ݔ��ئ�M]ӭ��G�g��M��ʆn(\<%Υ4�#ɠ�$)T��$A�Mi���Z2#�m�Bo{��6�`ׄ�R��$5�-��|H����Q�a�������X�m��B-�����C��|��+Ԁ��gm��M�#7������a�#F;�,��;���X闌 ��&��m��O��!�׃�]�)bcN�-1�Ew9�p״�)A�|G��
m	U��ibڻ'���}̀GP=��Ȥ�pJľ�>�C@��_R"h*:p��N9�F�Xt�]}O�����ז��˶>����DM�%�����=�TB��w	0��;�|��8�o�my1�6;�M7��c�o���?R���)�F��Ӌ%�XYS���@��R4������q��ĊX+
�L�(�5�4g����KL^�ɛ7Լ}M���h>��f�j޿~
�o����~qA�E�X?�� ro�@N��xg
4"��&�jS���Z�{�(�W(cP�P��X$�ۜ6���2�G�]wW�Ǌ�J���W�Q�5
��MV3��5ٗ���r��=v"�t�9e�3F?l"�-J"��^��D��V�I�����qx�EGU�du$��Qq]dU��=���#γ�\s-���
  �	     lib/auto/POSIX/autosplit.ixe�;o1�w�
�Y��A:&���h� )b�Y�;��+�Ώ_�d�w�H��wF;������z������s}�2�/���Pd�Nl�bQVU@�>��������[Δ���6 ��I�$�������,H������,�[1��A\!B���6��dJ�D��H8�@��O�id�1,��<j�?@�Σ�z�	z�2z4@⠻����q��;��	՟�[�l�0-�?Nˤ.?���V82[����Ǣ���n��Њ��{F�f��}��=�d,���#u5�H@����q��C��!j�IG������A�$)�HG��),��t�ތi����(z�1�,O��w22D
��Xc�baT+���Zc���6\:�_�p���
໮��ZŮ��q��Ƨ�l�g�=T;�o��@�v�h�1Z���QR��:����9D�c������ђK̰��#^N�L�P�th�<�8��Z��p���57�����>�qB��>WC�ӡEfH'�3��d@����{F� m��+ۤ�nSf~��M�_��+=,T��]���ܕ�34��!0�F�0����o�=_�6�Q%mT�]�ԇZ�ޔ7&1�(e..?^V��D?���_��j���D��|]��=�.�$��x��4{x��PK     -�A               lib/Module/PK    -�AD�![{  �     lib/Module/Find.pm�Umo�0����S��6�D��`�&ĆBHUY�a���	]�����%�3:������w���v�����HꌌOR��ʼo�Q|�	(y��вjN�`�y/<��W,�+�^F��tε�I*,/J��^#5���ǋ��38��7��A#��8IR��&dJ�^gG��*�]��?O�gE�KtZ}
$e�k��wI�I�lݓ�q��9����y�Ї�A�ȥ�=N?��m�Jw��}��u���]���5��ߘ�Һ�]�֙�ʣ!@���)�p�C�97�_�&�&xk�CQ%�f�"OP6U7��>����a��1��
���fdZW^�w8�
T["8/K��-C�ĉ��?�����aT�11a���|iQ�^����o\h����)6�����>R�Ը�2=|!v�*0��((�^~O6 0�6穓`J��1��٢�`:Μֻ���z�=ݝ�s0dM�L��c�W���m�t�	�����xG�V��ґ��z��ڟ��P:F鹅krlx��1h�pa~Ou��+��!5&"J*1N�j��w�U̟K���ӽ�\~/?���7b*+�G^���r6�ɽ���s�u-Kp^���Z� PK    -�A��ik  �     lib/ImVirt/VMD/Xen.pm�Vms�F��b'�b���MCkl���Ӵ��t����ڤ��{z1�`;�3�|��}nw�}���Eux�	�L(sܽ0?bT��W�H7�:�V�\:��_�'tj/�υ�h	0�y�H�fr��s���gS���D���`s_A��T�V����j�30�e蜷�3<�X1�*���w_��2��z]M�?�k�$��3	��s�@˙@�gj�l��/�u"�1��.S�D����c�MD�ˈ�#(�>K>�nFp�
'��r077��X�H=��@Z���dV@��������PH������\$(����x��d�Gmu�I0����QX���<&�|�$/�,`���8[����Cgؾ
�fي�s���{���	x4O<%iL�]8s�6���
���Q�[n�-��Dn�?�ỈTe0 ��x+�\T��K�E�6@��^�����a4�ɫbvyV��E�iYT��b�ͭ�ɚ�X4���#����o/F�!�}�/�Y�TS���ڲF��iY^�<t������<�1�Q<��tg����H}R̷�)gQLV�gL&=���}u9��IF.��tt��)��pN��]�
�2�rI+k�p�=�3xK�B4d�ԙ|tp�y��f��3j����d�ڽ�D?��)��
��T.k�
�*F*��R��d{�\��XI#1�2�;��I�����~�;��Ⱦ�������=0��?�i��y�9_$�;¡>�Ti�j�Rmr$LJ�I�	����*���nn�]m�!����X3�Z��Q�Eq�#̕�f�^��gP:�"M�S�n�݅�����f:+j+�4�����[#A&f?A�wy~$�ߋy�椐A�~y(��$�Id:���b����z&KR�l9j)�M�n/{V�<Q�?��ĉ.�t�I�&��D�&�= 0�Ɨ�����7��G�����Գ �.zBkn!͉G��f�cApуOƊ�?�7ڦ'�?.�G���Ļǉ�{�ǈ������!�۩��A���y�o}�X8�^�`���³��.�s�h�
@�s�F%��2%#�b�g#Aȁf� �%lP*��E}��B�(v�
![p%�6��{��u�{�v{��;���?|�}���S_�A�A}��P�5����U�W��3oz������/���B����&g��U����P��C�QT�W#	�9J:�~/qMS�r��"{��9ß�ۛ�I9�X�6c���&�� �_�"\��X�ܦe�Mr���Hbh6���k����l��rN	/���R��-�#b�9]���92��MC��������o{Oa�	�vʔc����\+�$C�1yX���r�|�z������sת�E
N�'���#��	�`<|�Is��e�0�'V-d|m�i���ބ����'l:l�1q	�Ҍ7�8��$\�5���K��x�'J0|�j�>iy�k�ƙ$5�Ta�Jv��Xͯ��Z��k���/�N�<���빚�\���A����>h��ޠ�PK    -�A�-�ɓ  ?     lib/ImVirt/VMD/VirtualBox.pm�T]��6}~���J)�WՇBw� Ð._J�QU����$�lJ���q`���L�C��s��=��m�2����5����Z�������j�P�����*�ßj��j*�B�h��<�%L��#���?�m��^��<?	��Lx������D�mw�``&`{w.���~���{���xlV���5� ����LB.�N�)�0� y����>�x�����I%ضPL���-. �!�N��^	#(����|����Xۄ	@���cۊ�,�*ܳ
sb��Y�Ѻ�
Is�^693���f1|U���A�O���Z��f|����X��c�SO1QR�G�$�E($FEbjB�'ۛ,VX�'�d9�5������iXq�4OQSg��ԉ��g8�k`Om������\�,XZ�gWSˁ��Y.܇&���0�o������y���╤/	!�H1��·��'�Y��g;�)�K3�`�����2�L8
F�F����|M���i����ٞ.�D0f��΅	.U	�Y �n�Ӿ�|���ʵ���y��������
���L�_���>Z��4��Xd��44��*5d��*���Mփů{�B�tƞ�7K����̚��iL,g4�ݏ�۰���Y̾
2)2H�.���k�N�"�0HAbĔ�l�k�!H����������)#h��1�7�W8�e�a��8K
@�g扊1�YdJ��ц�	B4i�Q\�
��{8,_�A����
�9�Yʆ|џ�����o8��Ʒ�&�)�+,�X�qF�ԙR��,D�tؽ��ؿ�Ƿ��������C�`�
��ي����E	�H�S�6b�2X���9�B��N2-�{k�������|ۢ� ]�B���9��q!d
�6�#K�i��k9А�����h��>�����?O��Zi��R�CN�}F�����R�M��K���}`N��$��R�I��ح�9�Bh�����D�"��V	s��=�F��>���.O��IZ��I�Uأ&,+�{�]�t��4�O�cag\�K�Z{���Q������b{P��H�6�����r�߈D���Ey�.�=�-�.!��?��ON�{2����x���}3/�Oi�63�����Ғe��^pD4����|�5��A|Z%ֵ�-JQ<^�Վp�I���3����툿FO��pG8dۃj+����n�����
�%�u��,��ǋ��{(Vw��78�@��v��5���=�/���ITnyj��Q��-����]݁�ϦR9����|*�~�,v�#v#䒾̇�s��/Q�2�0��N�/PK    -�A���@�       lib/ImVirt/VMD/UML.pm�U�r�F}6_ѵv
Q�����:�Yc+�VB��J�T��BSH��B�=�A�Nvכ�䉞�>�O��y�3�.�s�{.u�~򡽜�[y��v�K���̂%���ӫ]�XH�'��E���� ���??�U�
��8E��|k�I���u:�}���5l�s}�w�@���m���_c��~����ZG��o�rL.��S|� �b-Y
dF���I�^�$�\i�W�F�X���T�<�"�,2:F�(S"2���n1C����'	@��半1�Ց���J�J�13�E6 ��.a�R�z� c�4,ӥx	"/�
�$�y,r�)&J�rǓV�¨H��������fK��#<خkO��yS���x��i�p���$���0�wxG��;�#�#Ǜ�,0��`��v=g��.̗�|��i,����:G�WT�5�:��H�U�/	!f[�6ȷ��A@�����lm2%ﲘ,ذ5M� �	;�il�������&8Y�j�w]rcن�D0���!d��ҥ�������e��N����U����i3�}Z�A�F�����d<[��)������ˡﯠ�'!���8xe��j��A^�,�}STk�8]K\ӄ���ih����b���~�|T�*[���.�T��<Ӆ�*֯M�W��z	.��=\�#xO}��U���1�@��<hWjO�o�3a*�_#���� 6�����S�<�u�tQ��px����B�<� ?B}�h�&",w5+~���y��V�I�&ar�Ͻ�?������zK{�<��$�j_@'L c)�P/���U@�a꿏�>��6�t�NJ�/�)I���1�3�P��)�DZB��Z�h�4=��O�b�,6<�f(���e�ܨ��h4�(�+�|-���-�g�����!��Wۙ�]�cǝ�%*봐u!3�^�ɫ;��PK    -�Ac�L�  
	     lib/ImVirt/VMD/QEMU.pm�Umo�F�~���F"����^���&j��j�����Z�������k�^�����/�<3����4aB޹�	՘
��Z)li�	����S�u6*�B�i	0�yH�cr��C����q=�K��|/�*V0�I����h6�'��f��nܫ��sŖ�7�b ��J��Fc����Ư�� ���?���A
�\
D�|�v����� ��J��F!0A5���Gl�7Dt��(@P1�B�J�K�����
     lib/ImVirt/VMD/PillBox.pm�U�r�F�m��;
��q��\!�!7L�z��ҫ�/)b+�4\���Q���~
�e�p����K�@��9���h����/s��?�F�4����&�X�D�� b��XJU���5��D�V��8l�j4i<��UiK���v��no۳S*!kd���[CD*҅��:����� b�v��+���_�T�����2���ӷ���tZ��
wrǱ�di�h���\�%��o'�HWB�Y̑-�^�j�e�i}�Y�I�B[��
/@o�W\�c�1)��X ,�i�wf�2��3�Fd��� nC�F�&�&(��4ک%�s��1�I�[�zʍ71�����*�g��
b{pK����g��l��G1~��J��P����ۄ����bt��yP�/�:`j�4�mr({�p
�Q,[
c�
�~�륽]EL3�+.F�V�ɴ?N{���A�:�Fc��Z�sA��(s�g��e�V��J�>���E������AϿ�*Q呣�@/�q?�S�c��F�Q��/ai��#��-�r3��rzݛ�p�1Ď�b�!�H?�S��Q�~����h���2�<>��QA�(9��J���M�C����_�5��&W)U�0;֮�)�PK    -�A�C�R!  �     lib/ImVirt/VMD/OpenVZ.pm��[��F��ï8�Y- 1ܢ<�d7������a5�"d�2n����� 6����
�6J�C~��B*C�+7�TCF��a��e���b����x�<�1��נ2eRv��t��d�o��F ����4�1��;����|S6� �2������%�[��/��Y�e�3Ō�)O"I�'��"�T��'Ǜ.7��#>ٮk/��G�����T�D�'��<��3s�*���O9Ǿsf���s`�x�����+����ff�Xm��r}��T6F�+:G�W,eH�������j�/	�Gb�G��G����(~"�C5)G�b�����#"d�tpR����_z[��ہ���p��=�CÚ1|�H�:��ڔ�s������ ���S5.�/oв�qZV�:G��������5�����] 3m���������h�U'7/�5w�jmYÚZ_� bT�z��������ne���w�6��b_�A�i�m����/�}qx��A��n��epz��PQ��l!�s9Q��c't(T�y��l��;|���}�l�u��Y�ˍnUP6b�ݭ��nn��t���q��=�\��Nʊ��/%,�+\H��[,�y��*﹖'W�[Wm�Beh��>7���PK    -�A�/MR�  y     lib/ImVirt/VMD/LXC.pm�T]o�F}���D2VR�ܤ%�qL�/a���~�5f`��b�m����$R�۾�O��9gg��p����wnvϥ6�'��/�^��k�����mg��e�R�;F?�N��)u"��i	�'"c
�\="|�V��*�Ex]���I�N4�D�ܳ./�K0poF����"�e�|J�.l��n�������$Wxx�+(�XK�-c�J�z�$�a'JY#���R#p
�)!I�r��V�¸L�����fK��|t<ϙ�}BS��7���Y�r���$����%&��`D�����Cן�.0�y����|w�;̗�|���,�
k�o�׵"+#Ԍ����WQ|i	� �9D�����q�\�Z��"_י�2���lM��cȅ��Vrj-�ֶ�Էn����"�i�`AC��0Bv�F(]A'�ťe]�[�]X�\8�U�y�>ۦ��m��~�E������k
 ��Z�w�ȕ���ܛ}X|������l7Խb��ڶ��ܴmj�0VG�~�q̑�Z��kj1��&�� �;����� �F���Fj��ȝg�W��5���iW�
���4���\k���`�H
��:Z���>���`��4���{��θ{(�xyz^aJ�!��/�����Q�0����3�f�&�z�}{�_�=b`
C�H�����qӞ��_HT�!���9/,BY���PK    -�AM �87  �     lib/ImVirt/VMD/KVM.pm�Wmo�F�~��.F"R�C�����^H(/9Em�2��W�^kwMD��;���^H����>�ޝyv�y��u����ŷL(����~�o���k�7�z���̼������k:u2r!۴�<�$\1�@�)�??�i���wy�l*��Q�"�:n6$��f��n
��lI�y�S��{
r)6��@�H"���1�}؋��Đ+-���\�¶����G{D�EFA�e�@D���a����X'<�( )�͎�1��Ȕ
XC���B#p
�Q��K���ws������{�u�w?$oR�nq�O�4e&Y���@	1�rG7c�u&�wOy���fW��o]�an��3ZNl�Kw~��� ,���+u�J���!j�u����U�/	!f[$��[b� �����%
KD�.3%oSLlؚ��G�	݆���6Z|�mԷ
�	��3��DE��w=��d��Q�Q��E����}|�,�Hn��U�l�np||�uٖV [%�?27�?B��Y�]���מ%��<��k�=4N0�x���XU��j*r��:�D�`�ɫ?l�PK     -�A               lib/ImVirt/Utils/PK    -�A ~I  v     lib/ImVirt/Utils/uname.pm�T]o�6|ׯ\Z����^���X��mH��ma�m�HI����]QR ��I���pf��U.$�o���v��"7�J�����w��
y0���l<~W%�M��|�:ͿT�8�Z*mk��\wA��g|9u�x�r2��^�qzd�2�����ڬ�>��(X-)�z�]S�8��%Q�~�ޡ¾o��ԜM�Ks�&u��nϡR����9g�����;Z�$���Q���>����n�����0�n{hz����ѭa��?����ϋ<[iyq<������PK    -�A�יj  �     lib/ImVirt/Utils/sysfs.pm��m��8�_7���J���/��C�+X"m%����T��&qj;p��w��Y�J�W�xf~�ό��BT#���B��ڈB�Qg�_�����!l��Ӳa����߽��ɥ�ZI.K��(�3�/��������\𽬏J�r��,R�NY���g��1���ws�I/�j/��f�?sc��`p8�'��/�|��J���B�Vr�X	Zf�sh��S��Q6ز
��B%6���JR���ȎD�MEar�U�!3g<,�x�W����b{� ���;:�)6'�M�Y�
�$�������\i�1>�B�B*Gi3c�+��&vH�3�ܾk����BT�˚j�	IUDQ`��h�5E�1(�d�\'O�DQ�H�|��a�����%ʺ����̑
p�w��~N9�]�&OTfa���1f�VA����� �j�����
��?}�ܬ��)7�n��'�&}E���9�y�Ş�1l���x���
Y�\�m�ɶ�lG�Gd����]#���˿̷�����x3�0V=�KCL���>+�T]�Iml� �G�ao��p�uPU���/op2q�s2q���<��|��wkQ�j�O�L|2��Fվ���FPϦ��R���={�ކq�_���>�w�<�?V�(99=��Џ;n���:��V���r�~��rA�ְ?n�vyĭ��4�m5v_7���|qT�M��K��}�vǷo����[���������S�;�`���j�*R�C��Y��l�M�r)�?f4����ޫ-�k2��\Tv"��+��Ǔ9}#��PK    -�AP֑  7     lib/ImVirt/Utils/run.pm�T]o�H}^���$ >��ٶ8���
e�8h�kc�ﳵ�o�m�/�N���?0�L0�	�O2�t��45�������m��^��㪜s���s]�(]�_��qxf����=��Bے]��W�;4��S��d���3�C���м�[������<X��WN��9�͗q��c�N��f�su���u�R���G��P_~3dlYm^9��~�,50�c�)we�jd(��,�ij4��va����j��dҌ)�OXܬ�[u�?l����p}�����jF\Ӧ�6��7��=���6�6��,�'�{Ǔ�z���8���/PK    -�A/w��D  q     lib/ImVirt/Utils/procfs.pm��mo�6�_W����Ȗ�b/f�!J`�Rې�vAW�DY\$R%){ް�#7����+������H]T�S��~Ǥ�7�U�o��
5l���t@ԫa�˖T�/���\�7lu)��� -EM�1�@��|�ض��|#��d�R�BT9�]�d4���x�M��D� �r�2
��vJ�����aG�?Z��pEO�3(~'I
]R�T�
Da7��
/�I����� y�$�X@�d�XLK0���IƓ. �wݡ�wR"ց�bzR��SeX#�;�<y�m�d|��C��D��yJ1�	��ܲ(�%B�a�Gu�A�p�̆����-�خk�f�]Ҧb�+n��bq1��Ȅ���!>��ސl��ڙ�R0pf��t
��6Llw���׶��;O�
`�m���#�;|j�WP�xOV:R�V���GoE��BH���V0jɿ���?ԷN�7��Mj^�H�S����<�J��
ee�u��N��ԌV�m�8���C�,4�L��2�[ʨ��K�R4�����½t��:ח���KN�A�I��B�hj�#?���j�+z���ޏ���R�>-����J��$�,+dp�74?�w��wZ��_kP5�>U~�U_<�x���IS�=R��<��}5�4�)
��I�8��,�=W��I��/'�gJ�B5� ���I���r�bq��;�{�K��ZB43��7-�)�o�Cr��O�!�e=�#�3r0�j�Kh�ta(���~�L��	LU:�0/�JK���VV�����Q��_�p�7���i�D�Q�/�	}��	4�46�+|b������p����bb������E�!3��][#��J�l�EsC�1�}��fKhq��N�6�\�����oG��ρ@�S�f�t���?PK    -�A�J2�	  �     lib/ImVirt/Utils/kmods.pm�Tmo�6�����62�����M%�c�y1,�]�t-QITIʎx�}Gʪ�4X?
��Cy��T��~&!|!H�
JA�P���=X�|����J�y�(0$
��D���z
4���0��1�� +ϴEF4�yA�C:o�82�x���/`I��3t�K��u�°�D���L�0�5�D�b��w`Wh ,5�ϰ�)���c�S�%
m-i��g��޻+d;N'}���s�=�K�)�)�p�g�P�J�T:��8fTv���:����73��$)��ѯ�)Z�R%\�>�	ψ�&�(�M��m�ND1�!/�m�FTT^���{��j��<�b�B
��f&J}���������p� $���$�o� ���$�՞:�/!$91�۔�S@���2��`���Q����"��cs������T���&ea-0�B�ȄF�����X��*`̑�(��P�v;*$ޡW92���b����vl���D=�vL1���S��ܐ'�����,�,MaC��4.Ӷ�@4|��j	��>x��7]��]F+�ъ�eEʐ3$WL�P�-����y�y��_NGA ��<�{��?\�x���Y0� T���u�M���U����+Q_ABv�R�CuB����a!)Ϸ&SD�b���lqzX9Wm��c����5�O�m����6�qF�;\2�`�b$���6\q�4�����n�ܽ躰
<��:?._�o��?n����o�;��9����[Y��,��~����^�ࠄ���Sɰ���8VKOۥx�3|���{��2�}>[,+��Y�Q�:���*ih�N���E�Ϧ���v�&>g���QѸ�.��t��x���=��2ƈ���Y$�_L4AU)r�e��P��E6^[:�Fh��'��V���Dv�zm"��)\a��Ab�-͚��+H��n8N�RS|���>��׭��=:�0TÅ��]��M��W�׍���������]���6��$
��\A)�N��HDP"�&qGQA�
�s�%�V�k`E�r��h��XT �A�������7p�J����f<jJ R^�J1�mMd SSEx������r�KأT��&ə�BZ�iS�Q`�*>B��3�g���Bc��%OEI�R�$��e�E�&Uֵ
}$���du;#�����`=��!L+�a������_�r�Z.�I DSZ���sbgE��Q3Z�F��WQ}Y)�#�9B���D�x�?A��2Q�R�6�d�#����
��p���F�׳����v!(�^�yƊG�j��'D>̈́�]�J��>�`�y�+��'U�9���F�z�F��;�
���QK�eU���j��p����JiÉg��M�>�;��.����j%mУ[�/̏V��>�4�
�S���i���_���.p^��c����}��aa��ꭟoVۄG�^�l���w�ogB�i��AOuA���~�y�_����m�>K�i����?�l���)��-�'󫆼���PK    -�A��  �     lib/ImVirt/Utils/dmesg.pm�U[s�6~^���\6f�5�>6i���,dl�i��0�&��dͦ��G�
��j
��J��Ng�ݶK����C2Ik~&!|-H
x�� y��D��x�@АI%تP���. �!�v�E�A������niFI�X%,�% V�k��i�H�L�
�R��D1�
�	\�(-^ �ub� !��6�x߁C�!�̀�<ǚb��*�,I`E��4*����hxp��|��p�C����F��K7��bi�0�����0���h�9�k�����8�l�y0��0����;���Ѕ��{?��m �ja� �G�#3+leH�m�k��Jԗ��
���� �Fx��`+��Q8��԰���߲��G!��+��>���ڎ�Df{�
��jm�j*2}-ۿo�]���蒠$\�)��q7�����AI���<���d�`��Wn��6�,N�Qn�~�f������K���e�DB�4v�X���Xh�
H����,<"�)
QPT$xh67��Д
�,��̯$ v�鈌h ��H����E�F��b<�ex.`G��=t�"%c�0,6QZ� ���*>@L�sn˘�ύ�RC�{���ܳ8�
�2�#,�#��(�#sR���@�1�%̰V����h:�~~Y������/,�a�Ȯ�̈
t[�}*=}ٽ&7�;}�PK    -�A��`w�       lib/ImVirt/Utils/blkdev.pm�TQo�6~�~šiays,;�f-[ώ�I`��ah�d�D���zE��w�l$m��e/6u�����y*x�0�Wq��+,
�w�WE?��x,�����L�U�u>�B���9��.�W3�g	�-O����*��GA����-c𷣼!H��x>�P+�V�Z�
��͎)a/HY
3���� p����������ME�U�A����v	�X�b��Q���Ft��Z"�2�*��
�Jbf��*䴯`�J�7�90�@*��3c�+��M��=f�s��_W��h�r䅬�SA��rǅ�B�1oD�q�ǋ��r�������v���M��Ŗ����DM��̞8����xF9�U|/�L���$I`z7���"/o�9�/��wɤ�����u�]���F�z��@�դOdP�-R�S�[R� ���~�Z;����d醭izx�4=�)Ncc�׽u����A\���<$�6t� !�)ω|*�T=���X��`p>Ά?
`�]�zv�FC"��N��,�z�Pt�Ҿ�[d�\���bR��">�4J>�\^�Z�o��.�|Y=����~�v
M�*7S�G�a��PK     -�A               lib/ImVirt/Utils/dmidecode/PK    -�ANHp    "   lib/ImVirt/Utils/dmidecode/pipe.pm�T]s�6}��d���Ӈ��4��i�dl&�v�/��-y%B��ｒ
	���rg�Șq
�A�L����M�9�0��l��>��ScQk�`���D1.��� �P3�����%lP*����I�X!��j��b�"�A�#�a��c��F��_��rZ�$e�eqs�L�2�kV����O�w�	x�Gx���M���f�-n0�bI3���d������AoH�ʿ�'���ɨ?��. �`����^ ����n�o ���V�:/m�����v��#�WQ|q�p����
W4=l	\�l%������Z���5���Q�_����I`��$>���5�J�'��i�[��ϭ6L�eU*�;�vM]����k�[*Q��tz���L�p�W*���\wHSc�o�&�kƨ���TH�n�L٥?��#|�:{{�����s?�w#����
����1�f�dS�?>'��0�$�X�t6*�C��F���*�S�*��[+���<��ϡ���#Ef��E8�V�lv��~�n��Y
�G�YpԠ7�o�g��('[:�)����oON�8<Y�B��}B�K��p���=�h3�
�y�y�/�1���B�rZw��g?����
���c�o�'��rg<��W�"�8?�R�o� �a+�&���ˡr��y��α��W�(٢�6k#Mg����|!^����S�[�PK    -�A�{~�  f  $   lib/ImVirt/Utils/dmidecode/kernel.pm��mo�6�_ן���<8��a/j�Y�����I�����t��P�JRv�"��=Rv� Yl{#���ǻ�y x�Ѕz�}���3Å�����{T9�v��kP����V4,��a�k�v�ҤR�
%��e@�D!���Y3�}��"��k���4� �c_*�d̓��b�S�`R�*� 7����%樘��r!x�(�®�cXT �2�QL�Q�P�.�> �}+T��p�;dKl�T��1c�W �ؤ�7 �y�m;1^*�h<w�T�SJH�rͅ�B�1)E�1�>����l
��|
���zz�'k*6��
+�
�	M�)��
:
2_�L�ڊɢ{����	�Ҵ`�8���/k����ۂ0��-��Kf,��KyB�R��\jcM? ��n�s���Ӆ�$��j�÷w��s��{���^uU��Ul�#�wc
(��RW���Q���p����WM�璓ʃ/�T�j�����p�;���v�M��;��IxsM��N�۠�l�7W(
�	��K��,��B[�?%Ͻ��hA��D�^��ϱ�rlE�g�^��Hz�8�J�ʞ�+����o�y�Ř�C{�S�b��ԈqQ.���6�x\��Կä+J}�p_$����m;�/t����Д*ߞۯ=T�<6�ܶC�����V��:�"��ߠ�?(�ّ�?_?����_{tO�gE�+��4������h܂Ɖ5J�m�D8ShC8�O��HH�d��;����"X��>�����V/e �w�nu|�S�毩j���Qͦ�g��9���	K��(�4w��r�O�����?ի&,J�z�z��տ���٪D��R�n��
     lib/File/Which.pm�Vms7��b�9���v�1�'&���0���IR,�]}']N�@�ۻ�^�|*@Z�ˣ�G�T�Dp8��������$��<{[�Y���H|vf��ry�8��GG?��R�"��]wW�,4/ �V�"k;�ydDF��
ߖ/ջ������t���������m���_�o�\���Cp���1������y�'K¾'F�V����I�4������C��g�7p�+���.>��X����e��_ox���N�x�T���T'�\�O(5���J�L50��
t́�4*�h�a�0�����MR3,�rn$Zho�\�M�k�j1��H!��[p�^��5t�����Yl2���o�
W!�7��f��c�1@q
` �Ό�~ڰ0撞�}!���H����e��.��dB��
,9��Q��1���Bt���)�Zli�1��r��)l�a[ p�el8`b�A�5M؍g��z�t���͚�{�w�v��w$���B��L[G�?Ѣ�&E���g����3��ˡӔ�Zu� W̍�h��$ض���/�����I��ib�u-z������50�psU'EA���ͩ/���xw;��2����aZ}40sm�33V<Q��F6N"�i1M�dsl�߿�_�dk�6LL�j^��1?.�@�:��w+q��6i��ðZq�����1��i�&�K\ΐ�xE)�����iaoQW7�2|u��k_�%�E��J�����}�y�,t�4�t�5i���{q��:�r`�o����|�{�ĎS֧�����ȱ�͏)��d�:�8⻡��94��["�?}����̻cd�xܽ�����yrzZ�PK    -�A2]��  dD     lib/File/Slurp.pm�\�sG��l��l,�Ȓ��]�S2��n̪F��<�hF�!���o��Տ��y��P��Lw�>}���ytO��$�jG՟%��b֙M�Y_D�����߯��F����]%�,��ܧߋ�Ȓlblۓ��)n꽛�E�y|ge��X4���޳��_�V-izurz�+7�����5��"���:>�^N�yj�z����ޯ�N��������]�����S������K�L#h����\���+���������Д����<��V�h4��jk�")�����"|�f3�َ4f�5���QRV������ 7��q���(j	���ǐ|��F|��Y�wV耵V�IT�FDQ�6���B1�+��Cɿ���hG���F s�"6�����V^��4z7G��2&����;ۻ߫{�϶험�"��g7�y��Ou鹛`�uu����|h�8/P��|nT�cKVU�G��
�5Jet��L���e��� ��C0������ϩwP���kX�����є��<��@�Ԭ�˼��i��\�z��:�
��HF#��`J;aT4�F*/��B�	0����Fe|�=�Y�apbT�
�Л��}�s��wM ب(�K6�Y��9��A��498�&6������h��5�4n	�[���j��Sw�-��	 ���'���#�p=� ���l��m^4�յ��ǯd_����<(��Qv���=�޹w�gYw�`C���޲�ԟ�y��/���3ՠ@�^�"c`1������(�W	���c�l��HB�l"6$���*�/��UC^5������v޸�}�1Vl�t��M�'�j� �c��6��kY�-mn�- �Cˉ�BJځ�8�C �~�A����:|QA�G#Xu>�]ǥ5�%��]eMA��<E]��:��4�����#J� "�aF^"���`-I�Bͫ$nQv=�MxcѴŸ�2B���7'��m��Q��2�T#��e��T`4� p�������y�V���\ڞ)��er�<�1���i��A�$!�0�*�;�E��?<�)r��%#�hm�#�6x�4�
6Exs0�X���V#�g��,5�G���N���z���~�������.�;�� }$i�6սg�I��+����i �*Dho�L�,-�|m�&�&hI2��O~�)�ˋ
�v\��\�(��.^�)4��y&Fn}*�0�p	Njn[T���� �\$f$RN���g�n[4��S������r��������s�"�t��
�+�A5������g%���b�I��A�~W�7�s�;~���E1�-V��'�`&y��k'�=ع��3��r�vA��0;����BZ�߉��r���n��q��E��e���� �������3t���Ng���H�9p �w�,|� `?\���WŲ'��|�⢛���"��U
��93���g�#xQ\U������wY�@�}	ƌ��g�KA?4β���q�-@��ż�!z����
�ႊ8\7�訩|H�ภ7�F"��xe����wH����5��CNE�RE�ٹ�r���]�k&�p5%Ɗ����RDYv��!)Ye)X�!�|���g+��k�I(M@�sX�XJB�jEure�<?ƅN:�2�ja�Nat�� G���q���\�5l�8��u+�3�{�(~��)}� M��M*�$Y��-�o�d�b�}.^���`��#2p't�&��J��t|q�غ˄�WOg��{�󪘗[aN[�F^�h��"C>֗� �����@���tC Ap��!�jӀ��'�P˦bmueio=JL�T
���>��v��9� b�Tµ�2e�P��a��h�]�fE$Q�����Er-L���2�H��̓B���5[Ӑ�I���^�G�;��0�{RkAbp����g�Ǒ�(�h��2L�ԍ
�XJ�!G �2�Oq�瑑��0d.j������疲m�t!dL�/&OY> �����?/�� ��@���K� [���Ftrj��0X�.�����908�1��ُ�TRr���x��a�v�o����$����ы�~�kR>�K=�F��0@�y�[�������)�YE���_tgK�M\�+ $9	���V�V���xwg%���Q���O���!������
q�V)#SK��V�W4��E��w��2̃���ϥ=p���E�?����z2�� @l9�������1m�@�����C�U5� ���ae��a����^p9"��mpyi�O���~������8�����Dk$��:АI�- �	��a�th�Ux_%��9P��Ɔ�����+�FP�Q������ؗ�����C�j~N��,d��t6v�M�!P�B�$45h��L�B̶m?x�@I��N�1,�����R�:�u8�ǽpQ�%[0�O��+J�A��5��{/��v5<`
�6�T��B瞋"/�Yk�;��Ǫ�vpay�������W��}	�P�G+��\�څ�<�W�8I������g��_���Rh���`<ޛi����B�Ne�82��k� �4ǲ!��¸�ri78W��f�a����ѤjY��Z�o��P��f�nV�y�~Bv�� v���5�vqn��8vv�K�Y�
���o��lpa\�.�z㙋�Eti��p��]bٿܫޜ�+p��M���m�e�}%����S�h��7��u\�KUG��EM3_�0:΁�+X�}�U�g$��� <�0��w�%a[.��ܛT������}�f��Z�M��C�mc)a�4*.Xg�DD��u5���<`&�� �y��_"kfi��j�l��v9x�7l]������t���0$�I��)9C����\�.s@H,NI��D�}= /��A�E��R��], ��`���ՃEq��Z�GJ\ro���^�E/)^aR�j��y&���)�S<F�SE�^�,�t��=��NF��
�J��EZŷ-�*ٗ����|q�G�Jx����LavU��G*�˨���Z]�d���Kᰩ^Q��/�~��{���9VW�$��������4x���V,��4��l4/ɑ���ɳ�����X{�;�ڏ����5��ƀa�}������h�#,j�9�]�r��f��Alk�O �`U�dC��U�%M��O�"�z���<^]0���&Ƥ̜�_�t�|��uaDJ5�n���NV��i)e��{�v�Ϡ���oA�^��"��3�e��}�Q���*s}H�	�-s�-��5P�B����P�'�r�����s����b���`��j�ނD��$:��H�Z�_'jFr�E��aZ�ϳ(������_F�/����_���}�&E:tj�(S�%X�|(��jk|nq��q�y�z��ܬ:�0����Bm^�8n�
 �l@؄U��n���
b��?�I���J>ƛ4�U8��h�'���lk��ޭp%#:RS�ٯ
  �	            ��=�  lib/auto/POSIX/autosplit.ixPK     -�A                      �A��  lib/Module/PK    -�AD�![{  �            ����  lib/Module/Find.pmPK     -�A                      �AT�  lib/ImVirt/PK     -�A                      �A}�  lib/ImVirt/VMD/PK    -�A�c���              ����  lib/ImVirt/VMD/lguest.pmPK    -�A��ik  �            ��f�  lib/ImVirt/VMD/Xen.pmPK    -�A�����  �            ���  lib/ImVirt/VMD/VirtualPC.pmPK    -�A�-�ɓ  ?            ���  lib/ImVirt/VMD/VirtualBox.pmPK    -�A��xK�  '            ����  lib/ImVirt/VMD/VMware.pmPK    -�A���@�              ����  lib/ImVirt/VMD/UML.pmPK    -�Ac�L�  
	            ����  lib/ImVirt/VMD/QEMU.pmPK    -�A`9�J  �
            ���  lib/ImVirt/VMD/PillBox.pmPK    -�A�C�R!  �            ��� lib/ImVirt/VMD/OpenVZ.pmPK    -�A�/MR�  y            ��� lib/ImVirt/VMD/LXC.pmPK    -�AM �87  �            ��� lib/ImVirt/VMD/KVM.pmPK    -�A�0�Ϲ  �            �� lib/ImVirt/VMD/Generic.pmPK    -�A�a���  �            �� lib/ImVirt/VMD/ARAnyM.pmPK     -�A                      �A$ lib/ImVirt/Utils/PK    -�A ~I  v            ��S lib/ImVirt/Utils/uname.pmPK    -�A�יj  �            ��� lib/ImVirt/Utils/sysfs.pmPK    -�AP֑  7            ��� lib/ImVirt/Utils/run.pmPK    -�A/w��D  q            ��# lib/ImVirt/Utils/procfs.pmPK    -�AWK��L  �            ���& lib/ImVirt/Utils/pcidevs.pmPK    -�A�J2�	  �            ��+ lib/ImVirt/Utils/kmods.pmPK    -�A�u)�  �            ��^/ lib/ImVirt/Utils/jiffies.pmPK    -�A׳��R  �            ��?3 lib/ImVirt/Utils/helper.pmPK    -�A�x   �            ���6 lib/ImVirt/Utils/dmidecode.pmPK    -�A��  �            ��: lib/ImVirt/Utils/dmesg.pmPK    -�A~���  �            ��Q> lib/ImVirt/Utils/cpuinfo.pmPK    -�A��`w�              ��RB lib/ImVirt/Utils/blkdev.pmPK     -�A                      �A&F lib/ImVirt/Utils/dmidecode/PK    -�ANHp    "          ��_F lib/ImVirt/Utils/dmidecode/pipe.pmPK    -�A�{~�  f  $          ���J lib/ImVirt/Utils/dmidecode/kernel.pmPK     -�A            	          �A�N lib/File/PK    -�A8���  �
            ��O lib/File/Which.pmPK    -�A2]��  dD            ��)T lib/File/Slurp.pmPK    6 6 �
PAR.pm