# Genetics Browser

A working demo of the genome browser can be found [here](https://chfi.github.io/genetics-browser-example/track/).

You need [npm v5+](https://www.npmjs.com/), as well as the
[Purescript](http://www.purescript.org/) compiler and build tools. The
latter can be installed with npm:

```shell
npm --version
npm install -g purescript@"== 0.12.0" pulp psc-package
npm update
```

If you want to build in your HOME directory do something like this first

```shell
export NPM_PACKAGES="$HOME/.npm-packages"
echo "prefix = $NPM_PACKAGES" >> ~/.npmrc
```

Add the path

```shell
export PATH=$NPM_PACKAGES/bin:$PATH
purs --version
```

The browser can then be built using make, into the example folder at `./dist/app.js`:

``` shell
make build
```

That produces `./dist/app.js`. Opening `./dist/index.html`
should now display the genome browser.

The output path can be changed with the OUT option:

``` shell
make OUT=otherdist/index.js build
```

Pass `FLAGS=-w` to `make` for rebuilding on source code change.

``` shell
make FLAGS=-w build
```

The output app.js file can be loaded into an HTML file, doing so exposes
the genome browser Track module at a global variable, `GGB` by default.


Unit tests and QuickCheck tests can be run with
```shell
make test
```
