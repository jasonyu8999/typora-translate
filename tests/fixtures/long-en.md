# Machine Translation and Academic Writing

## Abstract

Machine translation has improved substantially over the past decade, and its
role in academic writing has expanded accordingly. This paper examines the
extent to which modern neural translation systems preserve the rhetorical
structure of scholarly prose. We analysed a corpus of one thousand abstracts
drawn from six disciplines and compared machine translations with human
reference translations. The results indicate that sentence-level adequacy is
now consistently high, while paragraph-level cohesion and terminological
consistency remain the principal sources of error.

## Introduction

Academic writing is characterised by long noun phrases, hedging expressions,
and dense chains of logical connectives. These features make scholarly prose
difficult to translate automatically, because a translation system must infer
relations that are only implicit in the surface text. Earlier rule-based
systems handled terminology well but produced awkward syntax, whereas
statistical systems produced fluent output that frequently misrepresented the
author's epistemic stance. Recent neural approaches attempt to combine
terminological fidelity with fluency, yet their behaviour on long documents is
still poorly understood.

## Method

We selected abstracts from six disciplines: linguistics, computer science,
medicine, economics, physics, and law. For each abstract we obtained a
professional translation and three machine translations produced by different
commercial systems. Raters scored each translation on adequacy, fluency, and
terminological consistency using a five-point scale. Inter-rater agreement was
measured with Krippendorff's alpha, and disagreements were resolved through
discussion.

## Results and Discussion

Adequacy scores were uniformly high across systems, with mean values above four
points. Fluency scores were slightly lower, particularly for sentences that
contained nested relative clauses. Terminological consistency varied
considerably across disciplines: medical and legal texts exhibited the largest
number of inconsistent term choices, while physics texts exhibited the fewest.
Paragraph-level cohesion was the weakest dimension overall, and errors of this
kind were rarely corrected by post-editing because reviewers tended to focus on
individual sentences.

These findings suggest that the evaluation of machine translation for academic
purposes should not be limited to sentence-level metrics. Document-level
measures are needed in order to capture the coherence of the translated text as
a whole. We therefore recommend that future studies report both sentence-level
and document-level scores, and that they describe the domain of the corpus in
sufficient detail for replication.

## Conclusion

Machine translation is now a practical aid for academic writing, but it cannot
replace careful human revision. The most effective workflows combine automatic
drafting with targeted human post-editing, especially for texts in which
terminological precision and logical structure are essential. Further research
should investigate how translation memory and terminology management can be
integrated into these workflows.