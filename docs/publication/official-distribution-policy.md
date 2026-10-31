# Official distribution policy for owner review

This is the proposed release policy, not a claim of legal review or a new grant
over third-party material. It is separate from a request to submit an app to Apple.

1. **Public source.** Original native-client/shared code is GPL-3.0-only. Original
   service/browser code is AGPL-3.0-only. Their complete source and notices are
   available for each published version. Commercial use and compliant forks are
   allowed; there is no additional noncommercial restriction.
2. **Official Apple builds.** Abrega distributes its official signed builds using
   the permissions it controls in original Banana material, separately from the
   public-source grants, together with the necessary upstream permissions. The
   public GPL grant does not prevent its copyright holders from separately
   authorizing official distribution. No blanket App Store exception for all
   redistributors is added to the GPL source licence by this policy.
3. **Upstream rights.** Separate official-distribution permission covers only
   rights actually controlled by its grantors. It cannot override a third-party
   licence. Full MIT/Apache notices for the eleven observed Swift packages and
   the service dependency notices are retained. Data, models and fonts keep
   their own licences; app icons and promotional branding remain separate.
4. **Contributions.** External pull requests remain closed until a reviewed
   contribution arrangement preserves the official-distribution permissions.
   A DCO or ordinary GPL contribution alone is not treated as a relicensing grant.
5. **Deployed source.** The service's source offer identifies the exact release
   commit. Its archive is downloadable without credentials or payment and
   includes required shared code, migrations, dependency pins and build inputs.
6. **Owner review.** Confirm the authority to license original Banana material,
   approve the proposed official-build distribution basis, and approve the exact
   publication candidate before making it public. Existing Apple submission and
   blog publication holds remain unchanged. If rights are uncertain, obtain
   appropriate legal review rather than assuming a licence exception solves them.

The current Git history records a single original author identity; that fact alone
does not prove employment/IP ownership or establish third-party permissions.
Synthetic sample artwork replaces the previously bundled real podcast covers.
No extra rights are asserted over real podcast recordings or cover art.

References checked October28,2026:

- [GNU GPL FAQ: rights holders and multiple licences](https://www.gnu.org/licenses/gpl-faq.html)
- [Apple's current standard application EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
- [Current Apple developer agreements](https://developer.apple.com/support/terms/)

Apple's standard EULA restricts redistribution and modification, with an
open-source-components qualification. Do not infer that this qualification alone
settles every GPL/App Store interaction. The official-build path above relies
on separately controlled rights and preserved upstream terms.
