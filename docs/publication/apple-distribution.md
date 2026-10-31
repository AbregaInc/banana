# Apple distribution rights review

Status: **unresolved publication gate**, not an effective exception or legal opinion.

The intended public source terms are GPL-3.0-only for native clients/shared code
and AGPL-3.0-only for the service. Official Apple binaries need an explicit,
reviewed distribution basis compatible with the rights in every included component.

## Proposed policy for owner review

Keep the public native source GPL-3.0-only. For official builds submitted by
Abrega, use a separate Apple-distribution permission from the holders of the
original Banana rights, while retaining every upstream dependency's terms.
Keep external pull requests closed until the contribution rights arrangement
supports this policy. This avoids silently adding an App Store exception to every
recipient's GPL grant. It does not authorize using someone else's GPL-only code
in an official binary under different terms.

The eleven observed native Swift packages have MIT/Apache2.0 upstream notices in
the current inventory. That narrows this review but does not establish ownership
of Banana's original code, all bundled data/models/media, or the legality of an
actual App Store binary. Decide explicitly whether independent redistributors
should also receive Apple-distribution permission; this proposal covers official
builds only. Final operative language and the rights-holder grant are still needed.

## Review steps

Before granting an exception or selecting separate official-binary terms:

1. Confirm the legal entity or people who hold the original code and artwork
   rights. Review contribution provenance; a commit's author field alone is not
   evidence of a copyright assignment or relicensing grant.
2. Inventory bundled dependencies, generated code, fonts, datasets, models and
   sample media. Keep all required notices. Separate Banana-owned material from
   upstream material whose licence cannot be changed by Banana.
3. Have counsel review current Apple distribution agreements against that inventory.
   Choose a narrow GPL additional permission or a separate official-distribution
   licence for rights actually controlled by its grantors. Do not invent an
   exception for upstream GPL material or assume a custom EULA overrides it.
4. Publish the final permission and explain whether it also covers independent
   redistributors. Update the source licence map and release notices consistently.
5. Before accepting external code, use a reviewed contributor agreement or other
   valid rights arrangement that preserves the chosen official-distribution path.
   A DCO sign-off alone does not grant broad relicensing rights.

The existing App Store submission hold remains in effect. Changing source notices
does not authorize a submission, repository visibility change, or retroactive
removal of rights already granted in earlier copies.

References:

- [GNU GPL FAQ: copyright holders and additional permissions](https://www.gnu.org/licenses/gpl-faq.html)
- [FSF's historical App Store enforcement discussion](https://www.fsf.org/news/2010-05-app-store-compliance/)
- [Apple developer agreements](https://developer.apple.com/support/terms/)
