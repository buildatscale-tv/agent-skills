/** Map a Hetzner location to its network zone (for private network subnets). */
export function networkZoneFor(location: string): string {
  const zones: Record<string, string> = {
    fsn1: "eu-central",
    nbg1: "eu-central",
    hel1: "eu-central",
    ash: "us-east",
    hil: "us-west",
    sin: "ap-southeast",
  };
  const zone = zones[location];
  if (!zone) {
    throw new Error(
      `No network zone mapping for location '${location}'. Add it to networkZoneFor() ` +
        "(see `hcloud network-zone` / Hetzner docs).",
    );
  }
  return zone;
}
