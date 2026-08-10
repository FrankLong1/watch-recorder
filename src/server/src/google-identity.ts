import { OAuth2Client } from "google-auth-library";
import { bearer } from "./auth";

export interface GooglePrincipal {
  subject: string;
  email: string | null;
  emailVerified: boolean;
}

export interface IdentityVerifier {
  verifyAuthorization(authorization: string | undefined, audience: string): Promise<GooglePrincipal | null>;
}

type GoogleTokenClient = Pick<OAuth2Client, "verifyIdToken">;

/// Verifies Google ID tokens locally against Google's rotating signing keys.
/// google-auth-library caches those keys according to their response headers;
/// no token introspection call sits on the audio hot path.
export class GoogleIdentityVerifier implements IdentityVerifier {
  constructor(private readonly client: GoogleTokenClient = new OAuth2Client()) {}

  async verifyAuthorization(
    authorization: string | undefined,
    audience: string,
  ): Promise<GooglePrincipal | null> {
    const idToken = bearer(authorization);
    if (!idToken) return null;

    try {
      const ticket = await this.client.verifyIdToken({ idToken, audience });
      const payload = ticket.getPayload();
      if (!payload?.sub) return null;
      if (payload.iss !== "accounts.google.com" && payload.iss !== "https://accounts.google.com") {
        return null;
      }
      return {
        subject: payload.sub,
        email: typeof payload.email === "string" ? payload.email : null,
        emailVerified: payload.email_verified === true,
      };
    } catch {
      // Invalid, expired, wrongly-audienced, and unverifiable tokens are all the
      // same external result. Never log a token or verifier exception detail.
      return null;
    }
  }
}

export function isAllowedUser(principal: GooglePrincipal, allowedSubjects: readonly string[]): boolean {
  return principal.emailVerified && allowedSubjects.includes(principal.subject);
}

export function isAllowedService(
  principal: GooglePrincipal,
  allowedServiceAccounts: readonly string[],
): boolean {
  return principal.emailVerified && principal.email !== null
    && allowedServiceAccounts.some((email) => email.toLowerCase() === principal.email!.toLowerCase());
}

/// Postgres user identity is derived from Google's immutable `sub`, never from
/// an email address that can be renamed or reassigned.
export function databaseUserId(principal: GooglePrincipal): string {
  return `google:${principal.subject}`;
}
