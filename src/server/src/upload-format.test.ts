import { describe, expect, test } from "bun:test";
import { isSupportedMemoUpload } from "./upload-format";

describe("isSupportedMemoUpload", () => {
  test("accepts only an explicitly declared M4A upload", () => {
    expect(isSupportedMemoUpload("audio/mp4", "m4a")).toBe(true);
    expect(isSupportedMemoUpload("Audio/MP4; charset=binary", " M4A ")).toBe(true);
  });

  test("rejects a raw capture or a missing format declaration", () => {
    expect(isSupportedMemoUpload("audio/mp4", undefined)).toBe(false);
    expect(isSupportedMemoUpload("audio/x-caf", "caf")).toBe(false);
    expect(isSupportedMemoUpload("audio/mp4", "caf")).toBe(false);
  });
});
