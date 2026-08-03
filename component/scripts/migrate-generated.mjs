import { readFileSync, rmSync, writeFileSync } from "node:fs";

function update(path, transform) {
  const before = readFileSync(path, "utf8");
  const after = transform(before);
  if (after !== before) {
    writeFileSync(path, after);
  }
}

update("impl/bindings.mbt", (source) =>
  source.replaceAll("derive(Show, Eq)", "derive(Debug, Eq)"),
);

const unitStores = [
  [
    "#|(func (param i32 i32) (result i32) (i32.store8 (local.get 0) (local.get 1)) (i32.const 0))",
    "#|(func (param i32 i32) (i32.store8 (local.get 0) (local.get 1)))",
  ],
  [
    "#|(func (param i32 i32) (result i32) (i32.store (local.get 0) (local.get 1)) (i32.const 0))",
    "#|(func (param i32 i32) (i32.store (local.get 0) (local.get 1)))",
  ],
  [
    "#|(func (param i32 i64) (result i32) (i64.store (local.get 0) (local.get 1)) (i32.const 0))",
    "#|(func (param i32 i64) (i64.store (local.get 0) (local.get 1)))",
  ],
  [
    "#|(func (param i32 f32) (result i32) (f32.store (local.get 0) (local.get 1)) (i32.const 0))",
    "#|(func (param i32 f32) (f32.store (local.get 0) (local.get 1)))",
  ],
  [
    "#|(func (param i32 f64) (result i32) (f64.store (local.get 0) (local.get 1)) (i32.const 0))",
    "#|(func (param i32 f64) (f64.store (local.get 0) (local.get 1)))",
  ],
];

update("gen/cabi/cabi.mbt", (source) => {
  for (const [legacy, current] of unitStores) {
    source = source.replaceAll(legacy, current);
  }
  return source;
});

update("gen/cabi/moon.pkg", (source) => {
  source = source.replace(
    'import(\n  "moonbitlang/core/encoding/utf8",\n)',
    'import {\n  "moonbitlang/core/encoding/utf8",\n}',
  );
  if (!source.includes('formatter(ignore: [ "cabi.mbt" ])')) {
    source += '\nformatter(ignore: [ "cabi.mbt" ])\n';
  }
  return source;
});

rmSync("moon.mod.json", { force: true });
