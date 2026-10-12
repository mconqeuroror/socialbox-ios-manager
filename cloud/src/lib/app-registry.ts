import registry from "../config/app-registry.json";

type GroupFields = "keychainInfoKeys" | "keychainSourceGroups" | "keychainGroupSuffixes";
export type AppDescriptor = Omit<(typeof registry)[number], GroupFields> & Record<GroupFields, readonly string[]>;
export const APP_DESCRIPTORS: readonly Readonly<AppDescriptor>[] = Object.freeze(
  registry.map((descriptor) => Object.freeze({ ...descriptor,
    keychainInfoKeys: Object.freeze([...descriptor.keychainInfoKeys]),
    keychainSourceGroups: Object.freeze([...descriptor.keychainSourceGroups]),
    keychainGroupSuffixes: Object.freeze([...descriptor.keychainGroupSuffixes]),
  })),
);

/** Only absent legacy fields default to Reddit; explicit null/unknown values fail closed. */
export function appDescriptorForType(value: unknown = undefined): Readonly<AppDescriptor> | undefined {
  const appType = value === undefined ? "reddit" : value;
  return typeof appType === "string" ? APP_DESCRIPTORS.find((descriptor) => descriptor.appType === appType) : undefined;
}

export function profileAppType(profile: { appType?: unknown }): string {
  const descriptor = appDescriptorForType(profile.appType);
  if (!descriptor) throw new Error("Unknown or malformed profile appType; records preserved for explicit repair");
  return descriptor.appType;
}

/** Console lists can request all apps. Legacy device lists remain Reddit-only. */
export function requestedAppFilter(request: Request, deviceRequest: boolean): string | undefined {
  const values = new URL(request.url).searchParams.getAll("appType");
  if (!values.length) return deviceRequest ? appDescriptorForType()!.appType : undefined;
  const descriptor = values.length === 1 ? appDescriptorForType(values[0]) : undefined;
  if (!descriptor) throw new Error("Unknown or ambiguous appType");
  return descriptor.appType;
}
