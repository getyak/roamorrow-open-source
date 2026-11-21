import next from "@next/eslint-plugin-next";
import typescriptParser from "@typescript-eslint/parser";

export default [
  next.configs.recommended,
  {
    files: ["**/*.{ts,tsx}"],
    languageOptions: { parser: typescriptParser },
  },
];
