FROM haskell:8.2

WORKDIR /opt/app

RUN cabal update

COPY ./kubetrail.cabal /opt/app/
RUN cabal install --only-dependencies -j$(nproc)

# Add and Install Application Code
COPY . /opt/app
RUN cabal install

CMD kubetrail ; sleep infinity
