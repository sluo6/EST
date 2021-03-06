#!/usr/bin/env perl

BEGIN {
    die "Please load efishared before runing this script" if not $ENV{EFISHARED};
    use lib $ENV{EFISHARED};
}

# This program creates bash scripts and submits them on clusters with torque schedulers, overview of steps below
#   Step 1 fetch sequences and get annotations
#       initial_import.sh       generates initial_import script that contains getsequence.pl and getannotation.pl or just getseqtaxid.pl if input was from taxid
#           getsequence.pl      grabs sequence data for input (other than taxid) submits jobs that do the following makes allsequences.fa
#           getannotations.pl   grabs annotations for input (other than taxid) creates struct.out file makes struct.out
#           getseqtaxid.pl      get sequence data and annotations based on taxid makes both struct.out and allsequences.fa
#   Step 2 reduce number of searches
#       multiplex.sh            performs a cdhit on the input 
#           cdhit is an open source tool that groups sequences based on similarity and length, unique sequences in sequences.fa
#           cdhit also creates sequences.fa.clustr for demultiplexing sequences later
#       if multiplexing is turned off, then this just copies allsequences.fa to sequences.fa
#   Step 3 break up the sequences so we can use more processors
#       fracfile.sh             breaks sequences.fa into -np parts for basting
#           fracsequence.pl     breaks fasta sequence into np parts for blasting
#   Step 4 Make fasta database
#       createdb.sh             makes fasta database out of sequences.fa
#           formatdb            blast program to format sequences.fa into database
#   Step 5 Blast
#       blast-qsub.sh           job array of np elements that blasts each fraction of sequences.fa against database of sequences.fa
#           blastall            blast program that does the compares
#   Step 6 Combine blasts back together
#       catjob.sh               concationates blast output files together into blastfinal.tab
#           cat                 linux program to read a file out
#   Step 7 Remove extra edge information
#       blastreduce.sh          removes like and reverse matches of blastfinal.tab and saves as 1.out
#           sort                sort blast results so that the best blast results (via bitscore) are first
#           blastreduce.pl      actually does the heavy lifting
#           rm                  removes blastfinal.tab
#   Step 8 Add back in edges removed by step 2
#       demux.sh                adds blast results back in for sequences that were removed in multiplex step
#           mv                  moves current 1.out to mux.out
#           demux.pl            reads in mux.out and sequences.fa.clustr and generates new 1.out
#   Step 9 Make graphs 
#       graphs.sh               creates percent identity and alignment length quartiles as well as sequence length and edge value bar graphs
#           mkdir               makes directory for R quartile information (rdata)
#           Rgraphs.pl          reads through 1.out and saves tab delimited files for use in bar graphs (length.tab edge.tab)
#           Rgraphs.pl          saves quartile data into rdata
#           paste               makes tab delimited files like R needs from rdata/align* and rdata/perid* and makes align.tab and perid.tab
#           quart-align.r       Makes alignment length quartile graph (r_quartile_align.png) from tab file
#           quart-perid.r       Makes percent identity quartile graph (r_quartile_perid.png) from tab file
#           hist-length.r       Makes sequence length bar graph (r_hist_length.png) from tab file
#           hist-edges.r        Makes edges bar graph (r_hist_edges.png) from tab file
#

use FindBin;
use Cwd qw(abs_path);
use File::Basename;
use Getopt::Long;
use POSIX qw(ceil);
use EFI::SchedulerApi;
use EFI::Util qw(usesSlurm getLmod);
use EFI::Config;


$result = GetOptions(
    "np=i"              => \$np,
    "queue=s"           => \$queue,
    "tmp=s"             => \$tmpdir,
    "evalue=s"          => \$evalue,
    "incfrac=f"         => \$incfrac,
    "ipro=s"            => \$ipro,
    "pfam=s"            => \$pfam,
    "accession-id=s"    => \$accessionId,
    "useraccession=s"   => \$accessionFile,
    "taxid=s"           => \$taxid,
    "gene3d=s"          => \$gene3d,
    "ssf=s"             => \$ssf,
    "blasthits=i"       => \$blasthits,
    "memqueue=s"        => \$memqueue,
    "maxsequence=s"     => \$maxsequence,
    "userfasta=s"       => \$fastaFile,
    "use-fasta-headers" => \$useFastaHeaders,
    "seq-count-file=s"  => \$seqCountFile,
    "lengthdif=s"       => \$lengthdif,
    "no-match-file=s"   => \$noMatchFile,
    "sim=s"             => \$sim,
    "multiplex=s"       => \$multiplexing,
    "domain=s"          => \$domain,
    "fraction=i"        => \$fraction,
    "random-fraction"   => \$randomFraction,
    "blast=s"           => \$blast,
    "job-id=i"          => \$jobId,
    "uniref-version=s"  => \$unirefVersion,
    "no-demux"          => \$noDemuxArg,
    "conv-ratio-file=s" => \$convRatioFile,
    "cd-hit=s"          => \$cdHitOnly,     # specify this flag in order to run cd-hit only after getsequence-domain.pl then exit.
    "uniref-expand"     => \$unirefExpand,  # expand to include all homologues of UniRef seed sequences that are provided.
    "scheduler=s"       => \$scheduler,     # to set the scheduler to slurm 
    "dryrun"            => \$dryrun,        # to print all job scripts to STDOUT and not execute the job
    "oldapps"           => \$oldapps,       # to module load oldapps for biocluster2 testing
    "oldgraphs"         => \$LegacyGraphs,  # use the old graphing code
    "config=s"          => \$configFile,    # new-style config file
);

die "Environment variables not set properly: missing EFIDB variable" if not exists $ENV{EFIDB};

my $efiEstTools = $ENV{EFIEST};
my $efiEstMod = $ENV{EFIESTMOD};
my $efiDbMod = $ENV{EFIDBMOD};
my $sortdir = '/scratch';

#defaults and error checking for choosing of blast program
if (defined $blast and $blast ne "blast" and $blast ne "blast+" and $blast ne "blast+simple" and $blast ne "diamond" and $blast ne 'diamondsensitive') {
    die "blast program value of $blast is not valid, must be blast, blast+, diamondsensitive, or diamond\n";
} elsif (not defined $blast) {
    $blast = "blast";
}

# Defaults and error checking for splitting sequences into domains
if (defined $domain and $domain ne "off" and $domain ne "on") {
    die "domain value of $domain is not valid, must be either on or off\n";
} elsif (not defined $domain) {
    $domain = "off";
}

# Defaults for fraction of sequences to fetch
if (defined $fraction and $fraction !~ /^\d+$/ and $fraction <= 0) {
    die "if fraction is defined, it must be greater than zero\n";
} elsif (not defined $fraction) {
    $fraction=1;
}

if (not $cdHitOnly or not $lengthdif or not $sim) {
    # Defaults and error checking for multiplexing
    if ($multiplexing eq "on") {
        if (defined $lengthdif and $lengthdif !~ /\d(\.\d+)?/) {
            die "lengthdif must be in a format like 0.9 |$lengthdif|\n";
        } elsif (not defined $lengthdif) {
            $lengthdif=1;
        }
        if (defined $sim and $sim !~ /\d(\.\d+)?/) {
            die "sim must be in a format like 0.9\n";
        } elsif (not defined $sim) {
            $sim=1;
        }
    } elsif ($multiplexing eq "off") {
        if (defined $lengthdif and $lengthdif !~ /\d(\.\d+)?/) {
            die "lengthdif must be in a format like 0.9 |$lengthdif|\n";
        } elsif (not defined $lengthdif) {
            $lengthdif=1;
        }
        if (defined $sim and $sim !~ /\d(\.\d+)?/) {
            die "sim must be in a format like 0.9\n";
        } elsif (not defined $sim) {
            $sim=1;
        } 
    } elsif (!(defined $multiplexing)) {
        $multiplexing = "on";
        if (defined $lengthdif and $lengthdif !~ /\d(\.\d+)?/) {
            die "lengthdif must be in a format like 0.9 |$lengthdif|\n";
        } elsif (not defined $lengthdif) {
            $lengthdif=1;
        }
        if (defined $sim and $sim !~ /\d(\.\d+)?/) {
            die "sim must be in a format like 0.9\n";
        } elsif (not defined $sim) {
            $sim=1;
        }
    } else {
        die "valid variables for multiplexing are either on or off\n";
    }
}


# At least one of tehse inputs are required to get sequences for the program
unless (defined $fastaFile or defined $ipro or defined $pfam or defined $taxid or defined $ssf or defined $gene3d or
        defined $accessionId or defined $accessionFile) {
    die "You must spedify the -fasta, -ipro, -taxid, -pfam, -accession-id, or -useraccession arguments\n";
}

# You also have to specify the number of processors for blast
unless (defined $np) {
    die "You must spedify the -np variable\n";
}

# Default queues
unless (defined $queue) {
    print "-queue not specified, using default\n";
    $queue = "efi";
}
unless (defined $memqueue) {
    print "-memqueue not specifiied, using default\n";
    $memqueue = $queue;
}

# Working directory must be defined
unless (defined $tmpdir) {
    die "You must spedify the -tmp variable\n";
}

# Default e value must also be set for blast, default set if not specified
unless (defined $evalue) {
    print "-evalue not specified, using default of 5\n";
    $evalue = "1e-5";
} else {
    if ( $evalue =~ /^\d+$/ ) { 
        $evalue = "1e-$evalue";
    }
}

if (not defined $configFile or not -f $configFile) {
    if (exists $ENV{EFICONFIG}) {
        $configFile = $ENV{EFICONFIG};
    } else {
        die "--config file parameter is not specified.  module load efiest_v2 should take care of this.";
    }
}

my $manualCdHit = 0;
$manualCdHit = 1 if (not $cdHitOnly and ($lengthdif < 1 or $sim < 1) and defined $noDemuxArg);

$seqCountFile = ""  unless defined $seqCountFile;

$np = ceil($np / 24) if ($blast=~/diamond/);

# Max number of hits for an individual sequence, normally set ot max value
$blasthits = 1000000 unless (defined $blasthits);

# Wet input families to zero if they are not specified
$pfam = 0           unless (defined $pfam);
$ipro = 0           unless (defined $ipro);
$taxid = 0          unless (defined $taxid);
$gene3d = 0         unless (defined $gene3d);
$ssf = 0            unless (defined $ssf);
$accessionId = 0    unless (defined $accessionId);
$randomFraction = 0 unless (defined $randomFraction);

# Default values for bandpass filter, 0,0 disables it, which is the default
$maxlen = 0         unless (defined $maxlen);
$minlen = 0         unless (defined $minlen);
$unirefVersion = "" unless (defined $unirefVersion);
$unirefExpand = 0   unless (defined $unirefExpand);
$domain = "off"     if $unirefVersion;

# Maximum number of sequences to process, 0 disables it
$maxsequence = 0    unless (defined $maxsequence);

# Fraction of sequences to include in graphs, reduces effects of outliers
unless (defined $incfrac) {
    print "-incfrac not specified, using default of 0.99\n";
    $incfrac=0.99;
}

($jobId = $ENV{PWD}) =~ s%^.*/(\d+)/*$%$1% if not $jobId;
$jobId = "" if $jobId =~ /\D/;

$noMatchFile = ""   unless defined $noMatchFile;

my $baseOutputDir = $ENV{PWD};
my $outputDir = "$baseOutputDir/$tmpdir";

my $pythonMod = getLmod("Python/2", "Python");
my $gdMod = getLmod("GD.*Perl", "GD");
my $perlMod = "Perl";
my $rMod = "R";

print "Blast is $blast\n";
print "domain is $domain\n";
print "fraction is $fraction\n";
print "random fraction is $randomFraction\n";
print "multiplexing is $multiplexing\n";
print "lengthdif is $lengthdif\n";
print "sim is $sim\n";
print "fasta is $fastaFile\n";
print "ipro is $ipro\n";
print "pfam is $pfam\n";
print "taxid is $taxid\n";
print "ssf is $ssf\n";
print "gene3d is $gene3d\n";
print "accession-id is $accessionId\n";
print "useraccession is $accessionFile\n";
print "no-match-file is $noMatchFile\n";
print "np is $np\n";
print "queue is $queue\n";
print "memqueue is $memqueue\n";
print "tmpdir is $tmpdir\n";
print "evalue is $evalue\n";
print "config is $configFile\n";
print "maxlen is $maxlen\n";
print "minlen is $minlen\n";
print "maxsequence is $maxsequence\n";
print "incfrac is $incfrac\n";
print "seq-count-file is $seqCountFile\n";
print "base output directory is $baseOutputDir\n";
print "output directory is $outputDir\n";
print "uniref-version is $unirefVersion\n";
print "manualcdhit is $manualCdHit\n";
print "uniref-expand is $unirefExpand\n";
print "Python module is $pythonMod\n";


my $accOutFile = "$outputDir/accession.txt";
my $errorFile = "$accOutFile.failed";


my $fracOutputDir = "$outputDir/fractions";
my $blastOutputDir = "$outputDir/blastout";

my $userHeaderFile = "";
my $userHeaderFileOption = "";
$userHeaderFile = "$outputDir/" . EFI::Config::FASTA_META_FILENAME;
$userHeaderFileOption = "-meta-file $userHeaderFile";

# Error checking for user supplied dat and fa files
if (defined $accessionFile and -e $accessionFile) {
    $accessionFile = $baseOutputDir . "/$accessionFile" unless ($accessionFile =~ /^\//i or $accessionFile =~ /^~/);
    $accessionFileOption = "-accession-file $accessionFile";

    $noMatchFile = "$outputDir/" . EFI::Config::NO_ACCESSION_MATCHES_FILENAME if !$noMatchFile;
    $noMatchFile = $baseOutputDir . "/$noMatchFile" unless ($noMatchFile =~ /^\// or $noMatchFile =~ /^~/);
    $noMatchFile = "-no-match-file $noMatchFile";

} elsif (defined $accessionFile) {
    die "accession file $accessionFile does not exist\n";
} else {
    $accessionFile = "";
}

my $accessionFileZip = $accessionFile;
if ($accessionFileZip =~ /\.zip$/i) {
    $accessionFile =~ s/\.zip$/.txt/i;
    $accessionFileOption =~ s/\.zip$/.txt/i;
}

my $seqCountFileOption = "";
if ($seqCountFile) {
    $seqCountFileOption = "-seq-count-file $seqCountFile";
}


#if (defined $fastaFile and -e $fastaFile) { # and -e $userHeaderFile) {
##} elsif (defined $userHeaderFile) {
#} else {
#    die "$userHeaderFile does not exist\n";
##} else {
##    print "this is userdat:$userHeaderFile:\n";
##    $userHeaderFile = "";
#}

my $fastaFileOption = "";
if (defined $fastaFile and -e $fastaFile) {
    $fastaFile = "$baseOutputDir/$fastaFile" unless ($fastaFile=~/^\// or $fastaFile=~/^~/);
    $fastaFileOption = "-fasta-file $fastaFile";
    $fastaFileOption = "-use-fasta-headers " . $fastaFileOption if defined $useFastaHeaders;
} elsif (defined $fastaFile) {
    die "$fastaFile does not exist\n";
} else {
    $fastaFile = "";
}

my $fastaFileZip = $fastaFile;
if ($fastaFileZip =~ /\.zip$/i) {
    $fastaFile =~ s/\.zip$/.fasta/i;
    $fastaFileOption =~ s/\.zip$/.fasta/i;
}


# Create tmp directories
#mkdir $tmpdir;
mkdir $outputDir;

# Write out the database version to a file
$efiDbMod=~/(\d+)$/;
print "database version is $1 of $efiDbMod\n";
system("echo $1 >$outputDir/database_version");

# Set up the scheduler API so we can work with Torque or Slurm.
my $schedType = "torque";
$schedType = "slurm" if (defined($scheduler) and $scheduler eq "slurm") or (not defined($scheduler) and usesSlurm());
my $usesSlurm = $schedType eq "slurm";
if (defined($oldapps)) {
    $oldapps = $usesSlurm;
} else {
    $oldapps = 0;
}


my $logDir = "$baseOutputDir/log";
mkdir $logDir;
$logDir = "" if not -d $logDir;
my %schedArgs = (type => $schedType, queue => $queue, resource => [1, 1, "35gb"], dryrun => $dryrun);
$schedArgs{output_base_dirpath} = $logDir if $logDir;
my $S = new EFI::SchedulerApi(%schedArgs);
my $jobNamePrefix = $jobId ? $jobId . "_" : ""; 

my $scriptDir = "$baseOutputDir/scripts";
mkdir $scriptDir;
$scriptDir = $outputDir if not -d $scriptDir;


########################################################################################################################
# Get sequences and annotations.  This creates fasta and struct.out files.
#
my $B = $S->getBuilder();
if ($pfam or $ipro or $ssf or $gene3d or ($fastaFile=~/\w+/ and !$taxid) or $accessionId or $accessionFile) {

    my $unirefOption = $unirefVersion ? "-uniref-version $unirefVersion" : "";
    my $unirefExpandOption = $unirefExpand ? "-uniref-expand" : "";

    $B->addAction("module load oldapps") if $oldapps;
    $B->addAction("module load $efiDbMod");
    $B->addAction("module load $efiEstMod");
    $B->addAction("cd $outputDir");
    $B->addAction("unzip -p $fastaFileZip > $fastaFile") if $fastaFileZip =~ /\.zip$/i;
    $B->addAction("unzip -p $accessionFileZip > $accessionFile") if $accessionFileZip =~ /\.zip$/i;
    if ($fastaFile) {
        $B->addAction("dos2unix -q $fastaFile");
        $B->addAction("mac2unix -q $fastaFile");
    }
    if ($accessionFile) {
        $B->addAction("dos2unix -q $accessionFile");
        $B->addAction("mac2unix -q $accessionFile");
    }
    # Don't enforce the limit here if we are using manual cd-hit parameters below (the limit
    # is checked below after cd-hit).
    my $maxSeqOpt = $manualCdHit ? "" : "-maxsequence $maxsequence";
    my $randomFractionOpt = $randomFraction ? "-random-fraction" : "";
    $B->addAction("$efiEstTools/getsequence-domain.pl -domain $domain $fastaFileOption $userHeaderFileOption -ipro $ipro -pfam $pfam -ssf $ssf -gene3d $gene3d -accession-id $accessionId $accessionFileOption $noMatchFile -out $outputDir/allsequences.fa $maxSeqOpt -fraction $fraction $randomFractionOpt -accession-output $accOutFile -error-file $errorFile $seqCountFileOption $unirefOption $unirefExpandOption -config=$configFile");
    $B->addAction("$efiEstTools/getannotations.pl -out $outputDir/struct.out -fasta $outputDir/allsequences.fa $userHeaderFileOption -config=$configFile");
    $B->jobName("${jobNamePrefix}initial_import");
    $B->renderToFile("$scriptDir/initial_import.sh");

    # Submit and keep the job id for next dependancy
    $importjob = $S->submit("$scriptDir/initial_import.sh");
    chomp $importjob;

    print "import job is:\n $importjob\n";
    @importjobline=split /\./, $importjob;

# Tax id code is different, so it is exclusive
} elsif ($taxid) {

    $B->addAction("module load oldapps") if $oldapps;
    $B->addAction("module load $efiDbMod");
    $B->addAction("module load $efiEstMod");
    $B->addAction("cd $outputDir");
    $B->addAction("$efiEstTools/getseqtaxid.pl -fasta allsequences.fa -struct struct.out -taxid $taxid -config=$configFile");
    if ($fastaFile=~/\w+/) {
        $fastaFile=~s/^-userfasta //;
        $B->addAction("cat $fastaFile >> allsequences.fa");
    }
    #TODO: handle the header file for this case....
    if ($userHeaderFile=~/\w+/) {
        $userHeaderFile=~s/^-userdat //;
        $B->addAction("cat $userHeaderFile >> struct.out");
    }
    $B->jobName("${jobNamePrefix}initial_import");
    $B->renderToFile("$scriptDir/initial_import.sh");

    $importjob = $S->submit("$scriptDir/initial_import.sh");
    chomp $importjob;

    print "import job is:\n $importjob\n";
    @importjobline=split /\./, $importjob;
} else {
    die "Error Submitting Import Job\n$importjob\nYou cannot mix ipro, pfam, ssf, and gene3d databases with taxid\n";
}


#######################################################################################################################
# Try to reduce the number of sequences to speed up computation.
# If multiplexing is on, run an initial cdhit to get a reduced set of "more" unique sequences.
# If not, just copy allsequences.fa to sequences.fa so next part of program is set up right.
#
$B = $S->getBuilder();
$B->dependency(0, @importjobline[0]);
$B->mailEnd() if defined $cdHitOnly;

# If we only want to do CD-HIT jobs then do that here.
if ($cdHitOnly) {
    $B->resource(1, 24, "20GB");
    $B->addAction("module load oldapps") if $oldapps;
    $B->addAction("module load $efiDbMod");
    $B->addAction("module load $efiEstMod");
    #$B->addAction("module load blast");
    $B->addAction("cd $outputDir");

    my @seqId = split /,/, $sim;
    my @seqLength = split /,/, $lengthdif;

    for (my $i = 0; $i <= $#seqId; $i++) {
        my $sLen = $#seqId == $#seqLength ? $seqLength[$i] : $seqLength[0];
        my $sId = $seqId[$i];
        my $nParm = ($sId < 1 and $sLen < 1) ? "-n 2" : "";
        ##$B->addAction("/home/n-z/noberg/dev/cd-hit-v4.6.8-2017-0621/cd-hit $nParm -c $sId -s $sLen -i $outputDir/allsequences.fa -o $outputDir/sequences-$sId-$sLen.fa -M 20000 -n 2 -T 24");
        $B->addAction("cd-hit $nParm -c $sId -s $sLen -i $outputDir/allsequences.fa -o $outputDir/sequences-$sId-$sLen.fa -M 20000 -n 2");
        $B->addAction("$efiEstTools/get_cluster_count.pl -id $sId -len $sLen -cluster $outputDir/sequences-$sId-$sLen.fa.clstr >> $cdHitOnly");
    }
    $B->addAction("touch  $outputDir/1.out.completed");

    $B->jobName("${jobNamePrefix}cdhit");
    $B->renderToFile("$scriptDir/cdhit.sh");
    $cdhitjob = $S->submit("$scriptDir/cdhit.sh");
    chomp $cdhitjob;
    print "CD-HIT job is:\n $cdhitjob\n";
    exit;
}

$B->addAction("module load oldapps") if $oldapps;
$B->addAction("module load $efiDbMod");
$B->addAction("module load $efiEstMod");
#$B->addAction("module load blast");
$B->addAction("cd $outputDir");

if ($multiplexing eq "on") {
    my $nParm = ($sim < 1 and $lengthdif < 1) ? "-n 2" : "";
    $B->addAction("cd-hit $nParm -c $sim -s $lengthdif -i $outputDir/allsequences.fa -o $outputDir/sequences.fa -M 10000");

    if ($manualCdHit) {
        $B->addAction(<<CMDS
if $efiEstTools/check_seq_count.pl -max-seq $maxsequence -error-file $errorFile -cluster $outputDir/sequences.fa.clstr
then
    echo "Sequence count OK"
else
    echo "Sequence count not OK"
    exit 1
fi
CMDS
            );
        $B->addAction("mv $outputDir/struct.out $outputDir/struct.demux.out");
        $B->addAction("$efiEstTools/remove_demuxed_nodes.pl -in $outputDir/struct.demux.out -out $outputDir/struct.out -cluster $outputDir/sequences.fa.clstr");
        $B->addAction("mv $outputDir/allsequences.fa $outputDir/allsequences.fa.before_demux");
        $B->addAction("cp $outputDir/sequences.fa $outputDir/allsequences.fa");
    }
    # Add in CD-HIT attributes to SSN
    if ($noDemuxArg) {
        $B->addAction("$efiEstTools/get_demux_ids.pl -struct $outputDir/struct.out -cluster $outputDir/sequences.fa.clstr -domain $domain");
    }
} else {
    $B->addAction("cp $outputDir/allsequences.fa $outputDir/sequences.fa");
}
$B->jobName("${jobNamePrefix}multiplex");
$B->renderToFile("$scriptDir/multiplex.sh");

$muxjob = $S->submit("$scriptDir/multiplex.sh");
chomp $muxjob;
print "mux job is:\n $muxjob\n";
@muxjobline=split /\./, $muxjob;


########################################################################################################################
# Break sequenes.fa into parts so we can run blast in parallel.
#
$B = $S->getBuilder();

$B->dependency(0, @muxjobline[0]);
$B->addAction("mkdir -p $fracOutputDir");
$B->addAction("$efiEstTools/splitfasta.pl -parts $np -tmp $fracOutputDir -source $outputDir/sequences.fa");
$B->jobName("${jobNamePrefix}fracfile");
$B->renderToFile("$scriptDir/fracfile.sh");

$fracfilejob = $S->submit("$scriptDir/fracfile.sh");
chomp $fracfilejob;
print "fracfile job is:\n $fracfilejob\n";
@fracfilejobline=split /\./, $fracfilejob;


########################################################################################################################
# Make the blast database and put it into the temp directory
#
$B = $S->getBuilder();

$B->dependency(0, @fracfilejobline[0]);
$B->addAction("module load oldapps") if $oldapps;
$B->addAction("module load $efiDbMod");
$B->addAction("module load $efiEstMod");
$B->addAction("cd $outputDir");
if ($blast eq 'diamond' or $blast eq 'diamondsensitive') {
    $B->addAction("module load diamond");
    $B->addAction("diamond makedb --in sequences.fa -d database");
} else {
    $B->addAction("formatdb -i sequences.fa -n database -p T -o T ");
}
$B->jobName("${jobNamePrefix}createdb");
$B->renderToFile("$scriptDir/createdb.sh");

$createdbjob = $S->submit("$scriptDir/createdb.sh");
chomp $createdbjob;
print "createdb job is:\n $createdbjob\n";
@createdbjobline=split /\./, $createdbjob;


########################################################################################################################
# Generate job array to blast files from fracfile step
#
my $blastFinalFile = "$outputDir/blastfinal.tab";

$B = $S->getBuilder();
mkdir $blastOutputDir;

$B->setScriptAbortOnError(0); # Disable SLURM aborting on errors, since we want to catch the BLAST error and report it to the user nicely
$B->jobArray("1-$np") if $blast eq "blast";
$B->dependency(0, @createdbjobline[0]);
$B->resource(1, 24, "14G") if $blast =~ /diamond/i;
$B->resource(2, 24, "14G") if $blast =~ /blast\+/i;

$B->addAction("export BLASTDB=$outputDir");
#$B->addAction("module load oldapps") if $oldapps;
#$B->addAction("module load blast+");
#$B->addAction("blastp -query  $fracOutputDir/fracfile-{JOB_ARRAYID}.fa  -num_threads 2 -db database -gapopen 11 -gapextend 1 -comp_based_stats 2 -use_sw_tback -outfmt \"6 qseqid sseqid bitscore evalue qlen slen length qstart qend sstart send pident nident\" -num_descriptions 5000 -num_alignments 5000 -out $blastOutputDir/blastout-{JOB_ARRAYID}.fa.tab -evalue $evalue");
$B->addAction("module load $efiDbMod");
$B->addAction("module load $efiEstMod");
if ($blast eq "blast") {
    $B->addAction("module load oldapps") if $oldapps;
    #$B->addAction("module load blast");
    $B->addAction("blastall -p blastp -i $fracOutputDir/fracfile-{JOB_ARRAYID}.fa -d $outputDir/database -m 8 -e $evalue -b $blasthits -o $blastOutputDir/blastout-{JOB_ARRAYID}.fa.tab");
} elsif ($blast eq "blast+") {
    $B->addAction("module load oldapps") if $oldapps;
    $B->addAction("module load BLAST+");
    $B->addAction("blastp -query $outputDir/sequences.fa -num_threads $np -db $outputDir/database -gapopen 11 -gapextend 1 -comp_based_stats 2 -use_sw_tback -outfmt \"6\" -max_hsps 1 -num_descriptions $blasthits -num_alignments $blasthits -out $blastFinalFile -evalue $evalue");
} elsif ($blast eq "blast+simple") {
    $B->addAction("module load oldapps") if $oldapps;
    $B->addAction("module load BLAST+");
    $B->addAction("blastp -query $outputDir/sequences.fa -num_threads $np -db $outputDir/database -outfmt \"6\" -num_descriptions $blasthits -num_alignments $blasthits -out $blastFinalFile -evalue $evalue");
} elsif ($blast eq "diamond") {
    $B->addAction("module load oldapps") if $oldapps;
    $B->addAction("module load DIAMOND");
    $B->addAction("diamond blastp -p 24 -e $evalue -k $blasthits -C $blasthits -q $outputDir/sequences.fa -d $outputDir/database -a $blastOutputDir/blastout.daa");
    $B->addAction("diamond view -o $blastFinalFile -f tab -a $blastOutputDir/blastout.daa");
} elsif ($blast eq "diamondsensitive") {
    $B->addAction("module load oldapps") if $oldapps;
    $B->addAction("module load DIAMOND");
    $B->addAction("diamond blastp --sensitive -p 24 -e $evalue -k $blasthits -C $blasthits -q $fracOutputDir/fracfile-{JOB_ARRAYID}.fa -d $outputDir/database -a $blastOutputDir/blastout.daa");
    $B->addAction("diamond view -o $blastFinalFile -f tab -a $blastOutputDir/blastout.daa");
} else {
    die "Blast control not set properly.  Can only be blast, blast+, or diamond.\n";
}
$B->addAction("OUT=\$?");
$B->addAction("if [ \$OUT -ne 0 ]; then");
$B->addAction("    echo \"BLAST failed; likely due to file format.\"");
$B->addAction("    echo $OUT > $outputDir/blast.failed");
$B->addAction("    exit 1");
$B->addAction("fi");
$B->jobName("${jobNamePrefix}blast-qsub");
$B->renderToFile("$scriptDir/blast-qsub.sh");

$B->jobArray("");
$blastjob = $S->submit("$scriptDir/blast-qsub.sh");
chomp $blastjob;
print "blast job is:\n $blastjob\n";
@blastjobline=split /\./, $blastjob;


########################################################################################################################
# Join all the blast outputs back together
#
$B = $S->getBuilder();

$B->dependency(1, @blastjobline[0]); 
$B->addAction("cat $blastOutputDir/blastout-*.tab |grep -v '#'|cut -f 1,2,3,4,12 >$blastFinalFile")
    if $blast eq "blast";
$B->addAction("SZ=`stat -c%s $blastFinalFile`");
$B->addAction("if [[ \$SZ == 0 ]]; then");
$B->addAction("    echo \"BLAST Failed. Check input file.\"");
$B->addAction("    touch $outputDir/blast.failed");
$B->addAction("    exit 1");
$B->addAction("fi");
#$B->addAction("rm  $blastOutputDir/blastout-*.tab");
#$B->addAction("rm  $fracOutputDir/fracfile-*.fa");
$B->jobName("${jobNamePrefix}catjob");
$B->renderToFile("$scriptDir/catjob.sh");
$catjob = $S->submit("$scriptDir/catjob.sh");
chomp $catjob;
print "Cat job is:\n $catjob\n";
@catjobline=split /\./, $catjob;


########################################################################################################################
# Remove like vs like and reverse matches
#
$B = $S->getBuilder();

$B->queue($memqueue);
$B->resource(1, 1, "50gb");
$B->dependency(0, @catjobline[0]); 
#$B->addAction("mv $blastFinalFile $outputDir/unsorted.blastfinal.tab");
$B->addAction("$efiEstTools/alphabetize.pl -in $blastFinalFile -out $outputDir/alphabetized.blastfinal.tab -fasta $outputDir/sequences.fa");
$B->addAction("sort -T $sortdir -k1,1 -k2,2 -k5,5nr -t\$\'\\t\' $outputDir/alphabetized.blastfinal.tab > $outputDir/sorted.alphabetized.blastfinal.tab");
$B->addAction("$efiEstTools/blastreduce-alpha.pl -blast $outputDir/sorted.alphabetized.blastfinal.tab -out $outputDir/unsorted.1.out");
$B->addAction("sort -T $sortdir -k5,5nr -t\$\'\\t\' $outputDir/unsorted.1.out >$outputDir/1.out");
$B->renderToFile("$scriptDir/blastreduce.sh");

$blastreducejob = $S->submit("$scriptDir/blastreduce.sh");
chomp $blastreducejob;
print "Blastreduce job is:\n $blastreducejob\n";

@blastreducejobline=split /\./, $blastreducejob;
my $depJob = @blastreducejobline[0];


########################################################################################################################
# If multiplexing is on, demultiplex sequences back so all are present
#
$B = $S->getBuilder();

$B->dependency(0, @blastreducejobline[0]); 
$B->addAction("module load oldapps") if $oldapps;
$B->addAction("module load $efiDbMod");
$B->addAction("module load $efiEstMod");
if ($multiplexing eq "on" and not $manualCdHit and not $noDemuxArg) {
    $B->addAction("mv $outputDir/1.out $outputDir/mux.out");
    $B->addAction("$efiEstTools/demux.pl -blastin $outputDir/mux.out -blastout $outputDir/1.out -cluster $outputDir/sequences.fa.clstr");
} else {
    $B->addAction("mv $outputDir/1.out $outputDir/mux.out");
    $B->addAction("$efiEstTools/removedups.pl -in $outputDir/mux.out -out $outputDir/1.out");
}

#$B->addAction("rm $outputDir/*blastfinal.tab");
#$B->addAction("rm $outputDir/mux.out");
$B->renderToFile("$scriptDir/demux.sh");

$demuxjob = $S->submit("$scriptDir/demux.sh");
chomp $demuxjob;
print "Demux job is:\n $demuxjob\n";
@demuxjobline=split /\./, $demuxjob;

$depJob = @demuxjobline[0];


########################################################################################################################
# Compute convergence ratio, before demultiplex
#
if ($convRatioFile) {
    $B = $S->getBuilder();
    $B->dependency(0, $depJob); 
    $B->addAction("$efiEstTools/calc_conv_ratio.pl -edge-file $outputDir/1.out -seq-file $outputDir/allsequences.fa > $outputDir/$convRatioFile");
    $B->renderToFile("$scriptDir/conv_ratio.sh");
    my $convRatioJob = $S->submit("$scriptDir/conv_ratio.sh");
    chomp $convRatioJob;
    print "Convergence ratio job is:\n $convRatioJob\n";
    my @convRatioJobLine=split /\./, $convRatioJob;
    $depJob = @convRatioJobLine[0];
}


########################################################################################################################
# Removed in favor of R, comments kept in case someone ever wants to use the pure perl solution
=pod Start comment
#submit the quartiles scripts, should not run until filterjob is finished
#nothing else depends on this scipt

$B->queue($memqueue);
$B->dependency(0, @demuxjobline[0]); 
$B->addAction("module load oldapps\n" if $oldapps);
$B->addAction("module load $efiDbMod");
$B->addAction("module load $efiEstMod");
$B->addAction("$efiEstTools/quart-align.pl -blastout $outputDir/1.out -align $outputDir/alignment_length.png");
$B->renderToFile("$scriptDir/quartalign.sh");

$quartalignjob = $S->submit("$scriptDir/quartalign.sh");
chomp $quartalignjob;
print "Quartile Align job is:\n $quartalignjob\n";


$B->queue($memqueue);
$B->dependency(0, @demuxjobline[0]); 
$B->addAction("#PBS -m e");
$B->addAction("module load oldapps\n" if $oldapps);
$B->addAction("module load $efiDbMod");
$B->addAction("module load $efiEstMod");
$B->addAction("$efiEstTools/quart-perid.pl -blastout $outputDir/1.out -pid $outputDir/percent_identity.png");
$B->renderToFile("$scriptDir/quartpid.sh");

$quartpidjob = $S->submit("$scriptDir/quartpid.sh");
chomp $quartpidjob;
print "Quartiles Percent Identity job is:\n $quartpidjob\n";


$B->queue($memqueue);
$B->dependency(0, @demuxjobline[0]); 
$B->addAction("module load oldapps\n" if $oldapps);
$B->addAction("module load $efiDbMod");
$B->addAction("module load $efiEstMod");
$B->addAction("$efiEstTools/simplegraphs.pl -blastout $outputDir/1.out -edges $outputDir/number_of_edges.png -fasta $outputDir/allsequences.fa -lengths $outputDir/length_histogram.png -incfrac $incfrac");
$B->renderToFile("$scriptDir/simplegraphs.sh");

$simplegraphjob = $S->submit("$scriptDir/simplegraphs.sh");
chomp $simplegraphjob;
print "Simplegraphs job is:\n $simplegraphjob\n";
=cut end comment


########################################################################################################################
# Create information for R to make graphs and then have R make them
#
$B = $S->getBuilder();

#my ($smallWidth, $fullWidth, $smallHeight, $fullHeight) = (700, 2000, 315, 900);
#$B->queue($memqueue);
#$B->dependency(0, $depJob);
#$B->mailEnd();
#$B->addAction("module load oldapps") if $oldapps;
#$B->addAction("module load $efiEstMod");
#$B->addAction("module load $efiDbMod");
#$B->addAction("$efiEstTools/R-hdf-graph.py -b $outputDir/1.out -f $outputDir/rdata.hdf5 -a $outputDir/allsequences.fa -i $incfrac");
#$B->addAction("Rscript $efiEstTools/quart-align-hdf5.r $outputDir/rdata.hdf5 $outputDir/alignment_length_sm.png $jobId $smallWidth $smallHeight");
#$B->addAction("Rscript $efiEstTools/quart-align-hdf5.r $outputDir/rdata.hdf5 $outputDir/alignment_length.png $jobId $fullWidth $fullHeight");
#$B->addAction("Rscript $efiEstTools/quart-perid-hdf5.r $outputDir/rdata.hdf5 $outputDir/percent_identity_sm.png $jobId $smallWidth $smallHeight");
#$B->addAction("Rscript $efiEstTools/quart-perid-hdf5.r $outputDir/rdata.hdf5 $outputDir/percent_identity.png $jobId $fullWidth $fullHeight");
#$B->addAction("Rscript $efiEstTools/hist-hdf5-length.r $outputDir/rdata.hdf5 $outputDir/length_histogram_sm.png $jobId $smallWidth $smallHeight");
#$B->addAction("Rscript $efiEstTools/hist-hdf5-length.r $outputDir/rdata.hdf5 $outputDir/length_histogram.png $jobId $fullWidth $fullHeight");
#$B->addAction("Rscript $efiEstTools/hist-hdf5-edges.r $outputDir/rdata.hdf5 $outputDir/number_of_edges_sm.png $jobId $smallWidth $smallHeight");
#$B->addAction("Rscript $efiEstTools/hist-hdf5-edges.r $outputDir/rdata.hdf5 $outputDir/number_of_edges.png $jobId $fullWidth $fullHeight");
#$B->addAction("touch  $outputDir/1.out.completed");
#$B->addAction("rm $outputDir/alphabetized.blastfinal.tab $outputDir/blastfinal.tab $outputDir/sorted.alphabetized.blastfinal.tab $outputDir/unsorted.1.out");

#create information for R to make graphs and then have R make them
$B->queue($memqueue);
$B->dependency(0, $depJob);
$B->mailEnd();
$B->setScriptAbortOnError(0); # don't abort on error
$B->addAction("module load oldapps") if $oldapps;
$B->addAction("module load $efiEstMod");
$B->addAction("module load $efiDbMod");
if (defined $LegacyGraphs) {
    $B->resource(1, 1, "90gb");
    $B->addAction("module load $gdMod");
    $B->addAction("module load $perlMod");
    $B->addAction("module load $rMod");
    $B->addAction("mkdir -p $outputDir/rdata");
    $B->addAction("$efiEstTools/Rgraphs.pl -blastout $outputDir/1.out -rdata  $outputDir/rdata -edges  $outputDir/edge.tab -fasta  $outputDir/allsequences.fa -length  $outputDir/length.tab -incfrac $incfrac");
    $B->addAction("FIRST=`ls $outputDir/rdata/perid* 2>/dev/null | head -1`");
    $B->addAction("if [ -z \"\$FIRST\" ]; then");
    $B->addAction("    echo \"Graphs failed, there were no edges. Continuing without graphs.\"");
    $B->addAction("    touch $outputDir/graphs.failed");
    $B->addAction("    touch  $outputDir/1.out.completed");
    $B->addAction("    exit 0 #Exit with no error");
    $B->addAction("fi");
    $B->addAction("FIRST=`head -1 \$FIRST`");
    $B->addAction("LAST=`ls $outputDir/rdata/perid*| tail -1`");
    $B->addAction("LAST=`head -1 \$LAST`");
    $B->addAction("MAXALIGN=`head -1 $outputDir/rdata/maxyal`");
    $B->addAction("Rscript $efiEstTools/quart-align.r $outputDir/rdata $outputDir/alignment_length.png \$FIRST \$LAST \$MAXALIGN");
    $B->addAction("Rscript $efiEstTools/quart-perid.r $outputDir/rdata $outputDir/percent_identity.png \$FIRST \$LAST");
    $B->addAction("Rscript $efiEstTools/hist-length.r  $outputDir/length.tab  $outputDir/length_histogram.png");
    $B->addAction("Rscript $efiEstTools/hist-edges.r $outputDir/edge.tab $outputDir/number_of_edges.png");
} else {
    $B->addAction("module load $pythonMod");
    $B->addAction("$efiEstTools/R-hdf-graph.py -b $outputDir/1.out -f $outputDir/rdata.hdf5 -a $outputDir/allsequences.fa -i $incfrac");
    $B->addAction("Rscript $efiEstTools/quart-align-hdf5.r $outputDir/rdata.hdf5 $outputDir/alignment_length_sm.png $jobId $smallWidth $smallHeight");
    $B->addAction("Rscript $efiEstTools/quart-align-hdf5.r $outputDir/rdata.hdf5 $outputDir/alignment_length.png $jobId $fullWidth $fullHeight");
    $B->addAction("Rscript $efiEstTools/quart-perid-hdf5.r $outputDir/rdata.hdf5 $outputDir/percent_identity_sm.png $jobId $smallWidth $smallHeight");
    $B->addAction("Rscript $efiEstTools/quart-perid-hdf5.r $outputDir/rdata.hdf5 $outputDir/percent_identity.png $jobId $fullWidth $fullHeight");
    $B->addAction("Rscript $efiEstTools/hist-hdf5-length.r $outputDir/rdata.hdf5 $outputDir/length_histogram_sm.png $jobId $smallWidth $smallHeight");
    $B->addAction("Rscript $efiEstTools/hist-hdf5-length.r $outputDir/rdata.hdf5 $outputDir/length_histogram.png $jobId $fullWidth $fullHeight");
    $B->addAction("Rscript $efiEstTools/hist-hdf5-edges.r $outputDir/rdata.hdf5 $outputDir/number_of_edges_sm.png $jobId $smallWidth $smallHeight");
    $B->addAction("Rscript $efiEstTools/hist-hdf5-edges.r $outputDir/rdata.hdf5 $outputDir/number_of_edges.png $jobId $fullWidth $fullHeight");
}
$B->addAction("touch  $outputDir/1.out.completed");
#$B->addAction("rm $outputDir/alphabetized.blastfinal.tab $blastFinalFile $outputDir/sorted.alphabetized.blastfinal.tab $outputDir/unsorted.1.out");
$B->renderToFile("$scriptDir/graphs.sh");

$graphjob = $S->submit("$scriptDir/graphs.sh");
chomp $graphjob;
print "Graph job is:\n $graphjob\n";


