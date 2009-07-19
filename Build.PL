use strict;
use warnings;

# The weaken() logic doesn't seem to work properly on 5.6. At least, it fails
# 20leakcheck.t (see http://rt.cpan.org/Ticket/Display.html?id=43799)
use 5.008;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'CPS',
   requires => {
               },
   build_requires => {
                 'Test::More' => 0,
               },
   license => 'perl',
   create_makefile_pl => 'traditional',
   create_license => 1,
   create_readme  => 1,
  );

$build->create_build_script;
