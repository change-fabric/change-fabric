import { useState } from "react";

export function App({ on }) {
  if (on) {
    useState(0);
  }
  return null;
}
