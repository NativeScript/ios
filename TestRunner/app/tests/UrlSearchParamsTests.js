describe("URL.searchParams caching", function () {
  it("returns the same object across reads", function () {
    const url = new URL("https://example.com/?a=1");
    expect(url.searchParams).toBe(url.searchParams);
  });

  it("parses the query string on the first read", function () {
    const url = new URL("https://example.com/?a=1&b=2&b=3");
    const sp = url.searchParams;
    expect(sp.get("a")).toBe("1");
    expect(sp.getAll("b")).toEqual(["2", "3"]);
    expect(sp.size).toBe(3);
  });

  it("keeps the same object after assigning to search", function () {
    const url = new URL("https://example.com/?a=1");
    const sp = url.searchParams;
    url.search = "?x=1";
    expect(url.searchParams).toBe(sp);
  });

  it("refreshes after assigning to search", function () {
    const url = new URL("https://example.com/?a=1");
    const sp = url.searchParams;
    expect(sp.get("a")).toBe("1");

    url.search = "?b=2&c=3";

    expect(url.searchParams.get("a")).toBe(null);
    expect(url.searchParams.get("b")).toBe("2");
    expect(url.searchParams.get("c")).toBe("3");
    expect(url.searchParams.size).toBe(2);
    expect(sp.get("b")).toBe("2");
  });

  it("refreshes after assigning to href", function () {
    const url = new URL("https://example.com/?a=1");
    const sp = url.searchParams;
    expect(sp.get("a")).toBe("1");

    url.href = "https://example.com/other?q=hello&lang=en";

    expect(url.searchParams).toBe(sp);
    expect(url.searchParams.get("a")).toBe(null);
    expect(url.searchParams.get("q")).toBe("hello");
    expect(url.searchParams.get("lang")).toBe("en");
  });

  it("refreshes to empty when the query is cleared", function () {
    const url = new URL("https://example.com/?a=1&b=2");
    const sp = url.searchParams;
    expect(sp.size).toBe(2);

    url.search = "";

    expect(url.searchParams).toBe(sp);
    expect(url.searchParams.size).toBe(0);
    expect(url.searchParams.toString()).toBe("");
  });

  it("preserves duplicate keys when refreshing", function () {
    const url = new URL("https://example.com/?a=1");
    const sp = url.searchParams;

    url.search = "?a=1&a=2&a=3";

    expect(url.searchParams.getAll("a")).toEqual(["1", "2", "3"]);
    expect(sp.getAll("a")).toEqual(["1", "2", "3"]);
  });

  it("writes mutations back to the url", function () {
    const url = new URL("https://example.com/?a=1");
    const sp = url.searchParams;

    sp.set("a", "9");
    expect(url.search).toBe("?a=9");

    sp.append("b", "2");
    expect(url.search).toBe("?a=9&b=2");
    expect(url.href).toBe("https://example.com/?a=9&b=2");

    sp.delete("a");
    expect(url.search).toBe("?b=2");

    sp.append("a", "0");
    sp.sort();
    expect(url.search).toBe("?a=0&b=2");
  });

  it("does not drop state on the read following a mutation", function () {
    const url = new URL("https://example.com/?a=1");
    const sp = url.searchParams;

    sp.append("b", "2");
    sp.append("b", "3");

    const spAfter = url.searchParams;
    expect(spAfter).toBe(sp);
    expect(spAfter.getAll("b")).toEqual(["2", "3"]);
    expect(spAfter.get("a")).toBe("1");
    expect(spAfter.size).toBe(3);
  });

  it("interleaves mutations and direct assignments", function () {
    const url = new URL("https://example.com/?a=1");
    const sp = url.searchParams;

    sp.set("a", "2");
    url.search = "?b=1";

    expect(url.searchParams.get("a")).toBe(null);
    expect(url.searchParams.get("b")).toBe("1");

    sp.set("c", "3");
    expect(url.search).toBe("?b=1&c=3");
    expect(url.searchParams.get("c")).toBe("3");
  });

  it("does not clobber a reassigned query when mutating a held reference", function () {
    const url = new URL("https://example.com/?a=1");
    const sp = url.searchParams;

    url.search = "?b=1";
    sp.set("c", "3");

    expect(url.search).toBe("?b=1&c=3");
    expect(sp.get("a")).toBe(null);
  });

  it("does not expose its cache as an enumerable property", function () {
    const url = new URL("https://example.com/?a=1");
    UNUSED(url.searchParams);
    url.search = "?b=2";
    UNUSED(url.searchParams);

    const keys = Object.keys(url);
    expect(keys.indexOf("_searchParams")).toBe(-1);
    expect(keys.indexOf("_searchParamsSource")).toBe(-1);

    const serialized = JSON.stringify(url);
    expect(serialized.indexOf("_searchParams")).toBe(-1);
    expect(serialized.indexOf("_searchParamsSource")).toBe(-1);

    for (const key in url) {
      expect(key).not.toBe("_searchParams");
      expect(key).not.toBe("_searchParamsSource");
    }
  });
});
