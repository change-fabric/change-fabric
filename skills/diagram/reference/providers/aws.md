# AWS provider profile

An architecture diagram that sets `data-provider="aws"` on its root draws AWS service icons and AWS group chrome. The pin, group kinds, colors, and fallback map live in `skills/diagram/packs/aws.yml`; this page explains how to use them. The shared markup is "Provider diagrams" in `../grammar.md`.

## Pack

`@squinch/pack-aws@0.19.0`, the AWS Architecture Icons release 04302026, redistributed unmodified. Fill the cache once per machine:

```
ruby ~/.claude/cf/bin/cloud_icons.rb aws
```

It runs `npm pack` in the pinned Node image, checks the sha512 in `aws.yml`, and extracts to `~/.cache/change-fabric/cloud-icons/aws/0.19.0/`. The repo never holds an AWS SVG. Slugs are the pack's `pack.json` keys (`lambda`, `rds`, `dynamodb`, `simple-storage-service`, `api-gateway`, `elastic-load-balancing`, `simple-queue-service`, `cloudfront`) plus its aliases (`s3`, `elb`, `ecs`, `eks`, `apigateway`).

## Groups

| kind (`data-group-kind`) | depth | border | corner slug |
| --- | --- | --- | --- |
| `cloud` | 1 | `#242F3E` solid | `cloud` |
| `region` | 2 | `#00A4A6` dashed | `region` |
| `vpc` | 3 | `#8C4FFF` solid | `virtual-private-cloud-vpc` |
| `availability-zone` | 4 | `#00A4A6` dashed | none |
| `public-subnet` | 5 | `#7AA116` solid | `public-subnet` |
| `private-subnet` | 5 | `#00A4A6` solid | `private-subnet` |
| `security-group` | 6 | `#DD344C` solid | none |
| `auto-scaling-group` | 6 | `#ED7100` dashed | `auto-scaling-group` |

A child kind is always strictly deeper than its parent, and nesting stops at 6. The border colors marked pack are read from the fill of the pack's own group icon; availability zone and security group have no group icon and follow AWS's published guidance.

Declare each border as a custom property named `--aws-<kind>` with the official value from the table, the same in both themes, and stroke the group's rect with `var(--aws-<kind>)`. That name is what makes the color palette-exempt; the same hex anywhere else is an ordinary off-palette color.

Group borders keep AWS's exact colors on the default skin, so `icon-contrast` does not grade them; some (the cloud navy on dark) fall under 3:1, which is accepted to match AWS's own diagrams. Icons and text keep their contrast checks.

## Contrast and plates

Most AWS service tiles fall under 3:1 on one theme: orange and green on light, purple and magenta and the cloud navy on dark. When `icon-contrast` flags a tile, put a `<rect class="plate" fill="#FFFFFF" rx="2">` first inside the icon's `g.icon`, and shrink the icon so the plate shows at least 2px on every side (a 32px plate holds a 26px icon). Never recolor the icon.

## Replicas

An AZ-mirrored resource is drawn once, inside the first AZ, with an `xN` sub-label (`x3`) after its name: one node, one icon, a count. This keeps a three-AZ deployment inside the 12-node cap. When the picture still overflows the 880px canvas, split by layer (network, compute, data) into `diagrams/<slug>/`.

## Attribution

`cloud_icons.rb` puts a notice comment in each icon group naming the AWS terms URL and the package it was fetched with. A page or walkthrough that ships the diagram adds `CloudIcons.notices(["aws"])` to its THIRD_PARTY_NOTICES. The icons are Amazon's; the notice cites `https://aws.amazon.com/architecture/icons/`, never the npm package's license.
