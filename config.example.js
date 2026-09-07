// Copy this to config.js, fill in the two values, and commit it.
// Both are safe to make public: the anon key grants nothing without a
// collection code (see supabase.sql).
//
// config.js is deliberately not included in the release zip, so unpacking a
// new version over your repo can never overwrite it. If it does get clobbered
// anyway, the app falls back to the last settings that worked on your device.
const CONFIG = {
  url:     "https://YOUR-PROJECT-REF.supabase.co",
  anonKey: "YOUR-ANON-KEY"
};
