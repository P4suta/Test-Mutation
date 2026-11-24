# The place where the tests of foreign distributions and their mutants run.
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
