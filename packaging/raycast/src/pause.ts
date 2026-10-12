import { runCLI } from "./pounce";

export default async function Command() {
  await runCLI(["pause"], "Pounce paused");
}
