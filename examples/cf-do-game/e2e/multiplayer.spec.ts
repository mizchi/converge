import { expect, test } from "@playwright/test";

test("2 clients: connect and movement sync", async ({ browser, request, baseURL }) => {
  const nameA = `Alpha-${Date.now().toString(36).slice(-5)}`;
  const nameB = `Bravo-${Date.now().toString(36).slice(-5)}`;

  const ctxA = await browser.newContext();
  const ctxB = await browser.newContext();

  const pageA = await ctxA.newPage();
  const pageB = await ctxB.newPage();

  await pageA.goto(`${baseURL}/?debug=1`);
  await pageB.goto(`${baseURL}/?debug=1`);

  await expect(pageA.locator("#status")).toContainText("Connected", { timeout: 30_000 });
  await expect(pageB.locator("#status")).toContainText("Connected", { timeout: 30_000 });
  await expect(pageA.locator("#status")).toContainText("online=2", { timeout: 30_000 });
  await expect(pageB.locator("#status")).toContainText("online=2", { timeout: 30_000 });

  await pageA.locator("#name").fill(nameA);
  await pageA.locator("#apply").click();
  await pageB.locator("#name").fill(nameB);
  await pageB.locator("#apply").click();

  await expect.poll(async () => {
    const res = await request.get(`${baseURL}/debug`);
    const body = await res.json() as {
      world: { players: Record<string, { name: string }> };
    };
    const names = Object.values(body.world.players).map((p) => p.name);
    return names.includes(nameA) && names.includes(nameB);
  }, { timeout: 20_000 }).toBeTruthy();

  const beforeRes = await request.get(`${baseURL}/debug`);
  const before = await beforeRes.json() as {
    world: { players: Record<string, { name: string; x: number }> };
  };
  const beforeA = Object.values(before.world.players).find((p) => p.name === nameA);
  expect(beforeA).toBeTruthy();

  await pageA.locator("canvas").click();
  await pageA.keyboard.down("ArrowRight");
  await pageA.waitForTimeout(800);
  await pageA.keyboard.up("ArrowRight");

  const targetX = (beforeA?.x ?? 0) + 24;

  await expect.poll(async () => {
    const res = await request.get(`${baseURL}/debug`);
    const body = await res.json() as {
      world: { players: Record<string, { name: string; x: number }> };
    };
    const player = Object.values(body.world.players).find((p) => p.name === nameA);
    return player?.x ?? -1;
  }, { timeout: 20_000 }).toBeGreaterThan(targetX);

  await expect.poll(async () => {
    return await pageB.evaluate((targetName) => {
      const dbg = (globalThis as { __convergeGameDebug?: { getWorldState: () => { players: Record<string, { name: string; x: number }> } } }).__convergeGameDebug;
      if (!dbg) return -1;
      const world = dbg.getWorldState();
      const player = Object.values(world.players).find((p) => p.name === targetName);
      return player?.x ?? -1;
    }, nameA);
  }, { timeout: 20_000 }).toBeGreaterThan(targetX);

  await ctxA.close();
  await ctxB.close();
});

test("single client: reload reconnect and continue movement sync", async ({ browser, request, baseURL }) => {
  const name = `Reload-${Date.now().toString(36).slice(-5)}`;
  const ctx = await browser.newContext();
  const page = await ctx.newPage();

  await page.goto(`${baseURL}/?debug=1`);
  await expect(page.locator("#status")).toContainText("Connected", { timeout: 30_000 });

  await page.locator("#name").fill(name);
  await page.locator("#apply").click();

  const getCurrentPeerId = async () => {
    return await page.evaluate(() => {
      const dbg = (globalThis as { __convergeGameDebug?: { getPeerId?: () => string } }).__convergeGameDebug;
      return dbg?.getPeerId?.() ?? "";
    });
  };

  const getServerXByPeer = async (peerId: string) => {
    const res = await request.get(`${baseURL}/debug`);
    const body = await res.json() as {
      world: { players: Record<string, { x: number }> };
    };
    return body.world.players[peerId]?.x ?? -1;
  };

  const peerId1 = await getCurrentPeerId();
  expect(peerId1.length).toBeGreaterThan(0);

  await expect.poll(async () => getServerXByPeer(peerId1), { timeout: 20_000 }).toBeGreaterThan(0);
  const beforeMove = await getServerXByPeer(peerId1);

  await page.locator("canvas").click();
  await page.keyboard.down("ArrowRight");
  await page.waitForTimeout(700);
  await page.keyboard.up("ArrowRight");

  await expect.poll(async () => getServerXByPeer(peerId1), { timeout: 20_000 }).toBeGreaterThan(beforeMove + 20);

  await page.reload();
  await expect(page.locator("#status")).toContainText("Connected", { timeout: 30_000 });

  await page.locator("#name").fill(name);
  await page.locator("#apply").click();

  const peerId2 = await getCurrentPeerId();
  expect(peerId2.length).toBeGreaterThan(0);

  await expect.poll(async () => getServerXByPeer(peerId2), { timeout: 20_000 }).toBeGreaterThan(0);
  const afterReconnect = await getServerXByPeer(peerId2);
  await page.locator("canvas").click();
  await page.keyboard.down("ArrowRight");
  await page.waitForTimeout(700);
  await page.keyboard.up("ArrowRight");

  await expect.poll(async () => getServerXByPeer(peerId2), { timeout: 20_000 }).toBeGreaterThan(afterReconnect + 20);

  await ctx.close();
});
