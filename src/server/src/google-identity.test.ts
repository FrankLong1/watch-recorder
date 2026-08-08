import { describe, expect, test } from "bun:test";
import { databaseUserId, GoogleIdentityVerifier, isAllowedService, isAllowedUser } from "./google-identity";

function ticket(payload: Record<string, unknown> | undefined) {
  return { getPayload: () => payload };
}

describe("Google identity", () => {
  test("passes the bearer token and exact audience to Google's verifier", async () => {
    const calls: unknown[] = [];
    const verifier = new GoogleIdentityVerifier({
      async verifyIdToken(options) {
        calls.push(options);
        return ticket({
          iss: "https://accounts.google.com",
          sub: "immutable-google-subject",
          email: "person@example.com",
          email_verified: true,
        }) as never;
      },
    });

    await expect(verifier.verifyAuthorization(
      "Bearer signed-google-id-token",
      "server-client.apps.googleusercontent.com",
    )).resolves.toEqual({
      subject: "immutable-google-subject",
      email: "person@example.com",
      emailVerified: true,
    });
    expect(calls).toEqual([{
      idToken: "signed-google-id-token",
      audience: "server-client.apps.googleusercontent.com",
    }]);
  });

  test("fails closed without leaking verifier errors", async () => {
    const verifier = new GoogleIdentityVerifier({
      async verifyIdToken() {
        throw new Error("private token verifier detail");
      },
    });

    expect(await verifier.verifyAuthorization(undefined, "audience")).toBeNull();
    expect(await verifier.verifyAuthorization("Basic nope", "audience")).toBeNull();
    expect(await verifier.verifyAuthorization("Bearer invalid", "audience")).toBeNull();
  });

  test("rejects a non-Google issuer even when a client returns a payload", async () => {
    const verifier = new GoogleIdentityVerifier({
      async verifyIdToken() {
        return ticket({ iss: "https://attacker.example", sub: "victim" }) as never;
      },
    });
    expect(await verifier.verifyAuthorization("Bearer forged", "audience")).toBeNull();
  });

  test("authorizes users by immutable subject and services by verified email", () => {
    const user = {
      subject: "stable-subject",
      email: "renamable@example.com",
      emailVerified: true,
    };
    expect(isAllowedUser(user, ["stable-subject"])).toBe(true);
    expect(isAllowedUser(user, ["renamable@example.com"])).toBe(false);
    expect(databaseUserId(user)).toBe("google:stable-subject");

    expect(isAllowedService(user, ["RENAMABLE@example.com"])).toBe(true);
    expect(isAllowedService({ ...user, emailVerified: false }, ["renamable@example.com"])).toBe(false);
    expect(isAllowedService({ ...user, email: null }, ["renamable@example.com"])).toBe(false);
  });
});
