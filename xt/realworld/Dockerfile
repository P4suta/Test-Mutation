# Build the distribution tests by default or select the shim target for older Perl interpreters.
# Build it from the root of the repository: docker build --file xt/realworld/Dockerfile .

FROM perl@sha256:91d3170a54b905f4237759ad0b8f9636a2aead9ff67200d864c2ca89eb76a96d AS tool

# cpm reads cpanfile.snapshot through Carton::Snapshot.
# Both directories stay outside the module search path, so no test of a distribution loads a module of the tool.
RUN cpanm --quiet --notest --local-lib-contained /opt/carton \
    https://cpan.metacpan.org/authors/id/M/MI/MIYAGAWA/Carton-v1.0.35.tar.gz
WORKDIR /opt/mutation
COPY cpanfile cpanfile.snapshot ./
RUN PERL5LIB=/opt/carton/lib/perl5 cpm install --local-lib-contained /opt/mutation --top-level-phase runtime \
    && rm -rf /root/.perl-cpm /root/.cpanm

FROM perl@sha256:cc3e7edf000b83217e8979124d9575409391bb07312b08c4ea237e2d3acb0046 AS perl5101
FROM perl@sha256:21171e4d8839f510a179e3dab25b22d9b784dce99a176e5f2fde99ec3f6f55db AS perl5144
FROM perl@sha256:708db9aa3c47f46ea896ddec1677cc3055c90ac6313e0798b81aaf446eab9796 AS perl5184
FROM tool AS shim
USER 0:0
COPY --from=perl5101 /usr/local/lib/perl5/5.10.1/ /usr/local/lib/perl5/5.10.1/
COPY --from=perl5101 /usr/local/lib/perl5/site_perl/5.10.1/ /usr/local/lib/perl5/site_perl/5.10.1/
COPY --from=perl5101 /usr/local/bin/perl5.10.1 /usr/local/bin/perl5.10.1
COPY --from=perl5144 /usr/local/lib/perl5/5.14.4/ /usr/local/lib/perl5/5.14.4/
COPY --from=perl5144 /usr/local/lib/perl5/site_perl/5.14.4/ /usr/local/lib/perl5/site_perl/5.14.4/
COPY --from=perl5144 /usr/local/bin/perl5.14.4 /usr/local/bin/perl5.14.4
COPY --from=perl5184 /usr/local/lib/perl5/5.18.4/ /usr/local/lib/perl5/5.18.4/
COPY --from=perl5184 /usr/local/lib/perl5/site_perl/5.18.4/ /usr/local/lib/perl5/site_perl/5.18.4/
COPY --from=perl5184 /usr/local/bin/perl5.18.4 /usr/local/bin/perl5.18.4
# The core library precedes site_perl on Perl 5.10, and its Test::More predates subtests.
COPY --from=perl5144 /usr/local/lib/perl5/5.14.4/Test/More.pm /usr/local/lib/perl5/5.10.1/Test/More.pm
COPY --from=perl5144 /usr/local/lib/perl5/5.14.4/Test/Builder.pm /usr/local/lib/perl5/5.10.1/Test/Builder.pm
COPY --from=perl5144 /usr/local/lib/perl5/5.14.4/Test/Builder/ /usr/local/lib/perl5/5.10.1/Test/Builder/
RUN useradd --home-dir /work/home --no-create-home --shell /bin/sh --uid 1000 tester
ENV HOME=/work/home TMPDIR=/work/tmp
USER 1000:1000
WORKDIR /repo
CMD ["sh", "-ec", "mkdir -p /work/tmp /work/home; for version in 5.10.1 5.14.4 5.18.4; do perl -I/opt/mutation/lib/perl5 xt/bin/measure-shim \"${version%.*}\" \"/usr/local/bin/perl$version\"; done"]

FROM tool AS distributions

# The archives and their dependencies arrive here, with the network, before any foreign test runs.
# A run of the image needs no network and writes below /work alone.
COPY xt/bin/realworld-prepare /opt/realworld/bin/realworld-prepare
COPY xt/realworld/distributions.toml /opt/realworld/realworld/distributions.toml
RUN --mount=type=cache,target=/root/.perl-cpm \
    perl -I/opt/mutation/lib/perl5 /opt/realworld/bin/realworld-prepare \
    /opt/realworld/realworld/distributions.toml /opt/distributions /opt/dependencies

# Some tests take another path for the superuser, so the runs belong to a user without rights.
RUN useradd --home-dir /work/home --no-create-home --shell /bin/sh --uid 1000 observer
USER 1000:1000
ENV HOME=/work/home TMPDIR=/work/tmp
WORKDIR /work
