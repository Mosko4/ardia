import assert from "node:assert/strict";
import { test } from "node:test";
import { blockedError, blockedLink, blockedNodes, classicPatBlocked, detailNodes, listingOf, mapGithub, restItems, restPr, restQuery, sectioned, withStacks } from "./github.ts";
import { LiveError } from "./types.ts";

const fixture = JSON.parse(await import("node:fs").then((fs) => fs.readFileSync(new URL("./fixtures/github.json", import.meta.url), "utf8")));
const all = [...fixture.data.authored.nodes, ...fixture.data.review.nodes];
const pr = (id) => ({ ...all.find((n) => n.id === id), state: "OPEN" });
const filters = { authored: true, reviewRequests: true };
const kind = (fn) => {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof LiveError);
    return error.kind;
  }
  return "ok";
};

test("a page without errors returns every PR", () => {
  const ids = all.slice(0, 3).map((n) => n.id);
  assert.deepEqual(detailNodes(ids, { data: { nodes: ids.map(pr) } }).map((n) => n.id), ids);
});

test("a field error keeps the PR, with that field empty", () => {
  const ids = all.slice(0, 2).map((n) => n.id);
  const nodes = ids.map(pr);
  nodes[1] = { ...nodes[1], commits: { nodes: [{ commit: { statusCheckRollup: null } }] } };
  const errors = [{ type: "FORBIDDEN", message: "no checks", path: ["nodes", 1, "commits", "nodes", 0, "commit", "statusCheckRollup"] }];
  const kept = detailNodes(ids, { data: { nodes }, errors });
  assert.deepEqual(kept.map((n) => n.id), ids);
  const items = mapGithub({ data: { ...fixture.data, authored: { nodes: kept }, review: { nodes: [] } } }, filters);
  assert.deepEqual(items.find((it) => it.id === `github:${ids[1]}`).pr.checks, []);
});

test("a PR GitHub can't find or won't show drops out; the rest stay", () => {
  const ids = all.slice(0, 3).map((n) => n.id);
  for (const type of ["NOT_FOUND", "FORBIDDEN"]) {
    const nodes = ids.map(pr);
    nodes[1] = null;
    const kept = detailNodes(ids, { data: { nodes }, errors: [{ type, message: type, path: ["nodes", 1] }] });
    assert.deepEqual(kept.map((n) => n.id), [ids[0], ids[2]]);
  }
});

test("a PR lost to anything else fails the page, and a rate limit says so", () => {
  const ids = all.slice(0, 2).map((n) => n.id);
  const lost = [pr(ids[0]), null];
  assert.equal(kind(() => detailNodes(ids, { data: { nodes: lost }, errors: [{ type: "SERVICE_UNAVAILABLE", message: "timeout", path: ["nodes", 1] }] })), "other");
  assert.equal(kind(() => detailNodes(ids, { data: { nodes: lost }, errors: [{ message: "Something went wrong" }] })), "other");
  assert.equal(kind(() => detailNodes(ids, { data: { nodes: lost } })), "other");
  assert.equal(kind(() => detailNodes(ids, { data: { nodes: [pr(ids[0])] } })), "other");
  assert.equal(kind(() => detailNodes(ids, { data: null })), "other");
  assert.equal(kind(() => detailNodes(ids, { data: { nodes: ids.map(pr) }, errors: [{ type: "RATE_LIMITED", message: "slow down" }] })), "rateLimited");
});

test("sections follow the search: authored first, then review requests, each pull request once", () => {
  const listing = listingOf(fixture);
  const rows = sectioned(listing, filters);
  assert.equal(new Set(rows.map((r) => r.id)).size, rows.length);
  assert.deepEqual(rows.map((r) => [`github:${r.id}`, r.section]), mapGithub(fixture, filters).map((it) => [it.id, it.section]));
  assert.deepEqual(sectioned(listing, { authored: false, reviewRequests: true }).map((r) => r.section).filter((s) => s === "authored"), []);
});

test("search nodes GitHub withheld (null) are skipped, not read", () => {
  const json = structuredClone(fixture);
  json.data.authored.nodes.unshift(null);
  json.data.direct.nodes.push(null);
  assert.deepEqual(listingOf(json).authored, listingOf(fixture).authored);
});

test("an organization's policy reads as Single Sign-On or a blocked token, with GitHub's fix link", () => {
  const at = (message) => ({ type: "FORBIDDEN", message, path: ["search", "nodes", 0] });
  const lifetime = at("The 'acme' organization forbids access via a fine-grained personal access tokens if the token's lifetime is greater than 366 days. Please adjust your token's lifetime at the following URL: https://github.com/settings/personal-access-tokens/23148248");
  assert.equal(blockedError(blockedNodes([lifetime])).kind, "tokenBlocked");
  assert.equal(blockedError(blockedNodes([at("Resource protected by organization SAML enforcement.")])).kind, "sso");
  assert.equal(blockedError(blockedNodes([{ ...lifetime, path: ["search", "nodes", 0, "commits"] }])), null);
  assert.equal(blockedError(blockedNodes([{ type: "NOT_FOUND", message: "x", path: ["search", "nodes", 0] }])), null);
  assert.equal(blockedLink(lifetime.message), "https://github.com/settings/personal-access-tokens/23148248");
  assert.equal(blockedLink("no link here"), null);
});

const classic = "`acme` forbids access via a personal access token (classic). Please use a GitHub App, OAuth App, or a personal access token with fine-grained permissions.";

test("only the classic token policy asks for the search API", () => {
  const at = (message) => [{ type: "FORBIDDEN", message, path: ["search", "nodes", 0] }];
  assert.equal(classicPatBlocked(at(classic)), true);
  assert.equal(classicPatBlocked(at("The 'acme' organization forbids access via a fine-grained personal access tokens if the token's lifetime is greater than 366 days.")), false);
  assert.equal(classicPatBlocked(at("Resource protected by organization SAML enforcement.")), false);
  assert.equal(classicPatBlocked([]), false);
});

test("a search API query keeps its terms and drops the GraphQL sort", () => {
  assert.equal(restQuery("is:pr is:open author:@me archived:false sort:updated-desc"), "is:pr is:open author:@me archived:false");
  assert.equal(restQuery("is:pr is:open user-review-requested:@me archived:false"), "is:pr is:open user-review-requested:@me archived:false");
});

test("a search API hit becomes the same pull request, minus what only GraphQL has", () => {
  const node = fixture.data.authored.nodes[0];
  const [item] = restItems({
    items: [
      {
        node_id: node.id,
        number: node.number,
        title: node.title,
        html_url: node.url,
        updated_at: node.updatedAt,
        draft: node.isDraft,
        comments: node.comments.totalCount,
        user: { login: node.author.login, avatar_url: node.author.avatarUrl },
        repository_url: "https://api.github.com/repos/acme/browser",
        pull_request: { merged_at: null },
      },
    ],
  });
  assert.equal(item.id, `github:${node.id}`);
  assert.equal(item.url, node.url);
  assert.equal(item.subtitle, `acme/browser #${node.number}`);
  assert.equal(item.pr.author, node.author.login);
  assert.equal(item.pr.comments, node.comments.totalCount);
  assert.equal(item.pr.repo, "acme/browser");
  assert.deepEqual(item.pr.checks, []);
  assert.equal(item.pr.review, null);
  assert.equal(item.pr.mergeable, "unknown");
  assert.equal(item.pr.headRef, "");
  assert.equal(item.pr.baseRef, "");
  assert.equal(item.pr.additions, 0);
  assert.equal(item.pr.unresolvedThreads, 0);
});

test("a search API hit without an identity or a pull request is left out", () => {
  const base = { number: 1, title: "x", html_url: "u", updated_at: "2026-01-01T00:00:00Z", repository_url: "https://api.github.com/repos/a/b" };
  assert.equal(restPr(base), null);
  assert.equal(restPr({ ...base, node_id: "PR_1" }), null);
  assert.equal(restPr({ ...base, node_id: "PR_1", pull_request: {} }).repository.nameWithOwner, "a/b");
  assert.deepEqual(restItems({ items: [] }), []);
  assert.deepEqual(restItems({}), []);
});

test("pull requests without branch names never stack", () => {
  const bare = (id, number) => ({
    id,
    source: "github",
    url: `https://github.com/acme/browser/pull/${number}`,
    title: "t",
    subtitle: "s",
    icon: null,
    updatedAt: 0,
    pr: { number, repo: "acme/browser", author: "a", authorAvatar: null, draft: false, headRef: "", baseRef: "", review: null, mergeable: "unknown", checks: [], comments: 0, unresolvedThreads: 0, additions: 0, deletions: 0, changedFiles: 0 },
  });
  assert.deepEqual(withStacks([bare("github:1", 1), bare("github:2", 2)]).map((it) => it.pr.stack), [undefined, undefined]);
});
