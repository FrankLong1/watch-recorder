import { expect, test } from "bun:test";
import { loadConfig } from "./config";

test("the watcher owner must be one of the allowed memo owners", () => {
  const priorAllowed = process.env.GOOGLE_ALLOWED_USER_SUBJECTS;
  const priorOwner = process.env.GOOGLE_WATCHER_OWNER_SUBJECT;
  try {
    process.env.GOOGLE_ALLOWED_USER_SUBJECTS = "owner-a";
    process.env.GOOGLE_WATCHER_OWNER_SUBJECT = "owner-b";
    expect(() => loadConfig()).toThrow("must also be present");
  } finally {
    if (priorAllowed === undefined) delete process.env.GOOGLE_ALLOWED_USER_SUBJECTS;
    else process.env.GOOGLE_ALLOWED_USER_SUBJECTS = priorAllowed;
    if (priorOwner === undefined) delete process.env.GOOGLE_WATCHER_OWNER_SUBJECT;
    else process.env.GOOGLE_WATCHER_OWNER_SUBJECT = priorOwner;
  }
});
