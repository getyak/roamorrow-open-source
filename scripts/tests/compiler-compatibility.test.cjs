const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, rmSync, symlinkSync, writeFileSync } = require("node:fs");
const { createRequire } = require("node:module");
const { join, resolve } = require("node:path");
const { test } = require("node:test");

const root = resolve(__dirname, "../..");
const webRoot = join(root, "apps/web");
const web = createRequire(join(webRoot, "package.json"));

test("the web compiler passes Next.js preflight and still rejects type errors", () => {
  // A native-only compiler can pass `tsc` while breaking Next's compiler API.
  // Exercise the actual Next preflight without starting a production build.
  const fixture = mkdtempSync(join(webRoot, ".compiler-compatibility-"));
  try {
    symlinkSync(join(webRoot, "node_modules"), join(fixture, "node_modules"), "dir");
    writeFileSync(
      join(fixture, "tsconfig.json"),
      JSON.stringify({
        extends: join(root, "tsconfig.base.json"),
        compilerOptions: { noEmit: true },
        include: ["sample.ts"],
      }),
    );
    const script = `
      const { verifyAndRunTypeScript } = require(${JSON.stringify(web.resolve("next/dist/lib/verify-typescript-setup"))});
      verifyAndRunTypeScript({
        dir: process.cwd(), distDir: ".next", cacheDir: process.cwd() + "/.next/cache",
        appDir: process.cwd(),
        tsconfigPath: "tsconfig.json", shouldRunTypeCheck: true,
        strictRouteTypes: false, typedRoutes: false,
        disableStaticImages: false, hasAppDir: true, hasPagesDir: false,
      }).then(({ result }) => {
        if (!result || result.inputFilesCount === 0) process.exitCode = 2;
      }).catch((error) => { console.error(error); process.exitCode = 1; });
    `;
    const check = () =>
      spawnSync(process.execPath, ["-e", script], {
        cwd: fixture,
        env: { ...process.env, CI: "true" },
        encoding: "utf8",
        timeout: 30_000,
      });
    writeFileSync(join(fixture, "sample.ts"), 'export const label: string = "Roamorrow";\n');
    const valid = check();
    assert.ifError(valid.error);
    assert.equal(valid.status, 0, `${valid.stdout}\n${valid.stderr}`);

    writeFileSync(join(fixture, "sample.ts"), "export const label: string = 42;\n");
    const invalid = check();
    assert.ifError(invalid.error);
    assert.equal(invalid.status, 1, `${invalid.stdout}\n${invalid.stderr}`);
    assert.match(invalid.stderr, /not assignable to type 'string'/);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
