// A skill may ship one example of its own output as skills/<id>/example.svg.
// It is copied next to the built site and served as an image. Its <title> is
// the alt text and its width and height reserve the space before it loads.
export function exampleMeta(svg, dirName) {
  const title = svg.match(/<title[^>]*>([^<]*)<\/title>/);
  const width = svg.match(/<svg[^>]*\swidth="(\d+)"/);
  const height = svg.match(/<svg[^>]*\sheight="(\d+)"/);
  if (!title || !width || !height) {
    throw new Error(`skills/${dirName}/example.svg: needs a <title> and a numeric width and height on the root`);
  }
  return {
    src: `/reference-examples/${dirName}.svg`,
    alt: title[1].trim(),
    width: Number(width[1]),
    height: Number(height[1]),
  };
}
