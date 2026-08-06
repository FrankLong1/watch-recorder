import { describe, expect, test } from "bun:test";
import { parseRoute } from "./routing";

describe("parseRoute", () => {
  test("strips a routing prefix and keeps it as metadata", () => {
    expect(parseRoute("Investment idea — buy more NVDA before earnings")).toEqual({
      route: "investment idea",
      body: "buy more NVDA before earnings",
    });
  });

  test("accepts whichever separator the model happened to punctuate with", () => {
    for (const separator of ["—", "–", "-", ":", ","]) {
      expect(parseRoute(`Follow up ${separator} call the broker`)).toEqual({
        route: "follow up",
        body: "call the broker",
      });
    }
  });

  test("is case insensitive", () => {
    expect(parseRoute("TRADE OBSERVATION: spreads widened again").route).toBe(
      "trade observation",
    );
  });

  test("requires a separator, so an ordinary sentence is not routed", () => {
    expect(parseRoute("Follow up on that later this week")).toEqual({
      route: null,
      body: "Follow up on that later this week",
    });
  });

  test("leaves an unprefixed memo whole", () => {
    const transcript = "The thesis on this name has not changed.";
    expect(parseRoute(transcript)).toEqual({ route: null, body: transcript });
  });

  test("trims surrounding whitespace", () => {
    expect(parseRoute("  Investment idea —  short duration  ")).toEqual({
      route: "investment idea",
      body: "short duration",
    });
  });
});
