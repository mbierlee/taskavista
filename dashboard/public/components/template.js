/* Component markup lives beside each component as a .html file, holding the
   <style> block and the shadow tree it describes.

   There is no build step, so the browser fetches that file at module load. The
   caller awaits it at the top level of its module, which holds the custom
   element's definition back until its markup is in hand — app.js only runs once
   every element it imports is defined. */

/* Resolved against this module rather than the page, so a name is relative
   to this directory — where the templates sit — and not to whichever
   document happens to be loading the component. */
async function fetchText(file) {
  const url = new URL(file, import.meta.url);
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(
      `Could not load ${url}: ${response.status} ${response.statusText}`,
    );
  }
  return response.text();
}

/* One sheet, adopted by every shadow root, so it is parsed once however many
   components there are. */
const sharedStyles = new CSSStyleSheet();
sharedStyles.replaceSync(await fetchText("shared.css"));

export async function loadTemplate(file) {
  const template = document.createElement("template");
  template.innerHTML = await fetchText(file);
  return template;
}

/* Gives `host` its shadow root: the shared styles, then `template`. */
export function attachTemplate(host, template) {
  const root = host.attachShadow({ mode: "open" });
  root.adoptedStyleSheets = [sharedStyles];
  root.append(template.content.cloneNode(true));
  return root;
}
