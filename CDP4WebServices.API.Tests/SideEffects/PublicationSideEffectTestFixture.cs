﻿// --------------------------------------------------------------------------------------------------------------------
// <copyright file="PublicationSideEffectTestFixture.cs" company="RHEA System S.A.">
//   Copyright (c) 2016 RHEA System S.A.
// </copyright>
// <summary>
//   Publication Side Effect test class
// </summary>
// --------------------------------------------------------------------------------------------------------------------

namespace CDP4WebServices.API.Tests.SideEffects
{
    using System;
    using System.Collections.Generic;
    using API.Helpers;
    using CDP4Common.DTO;
    using CDP4Common.Types;
    using CDP4WebServices.API.Services;
    using CDP4WebServices.API.Services.Authorization;
    using CDP4WebServices.API.Services.Operations.SideEffects;
    using Moq;
    using Npgsql;
    using NUnit.Framework;

    [TestFixture]
    internal class PublicationSideEffectTestFixture
    {

        private PublicationSideEffect publicationSideEffect;
        private Mock<IParameterService> parameterService;
        private Mock<IParameterOverrideService> OverideService;
        private Mock<IParameterValueSetService> parameterValueSetService;
        private Mock<IParameterOverrideValueSetService> overrideValueSetService;
        private Mock<ICdp4TransactionManager> transactionManager;
        private Mock<ISecurityContext> securityContext;
        private Iteration iteration;
        private NpgsqlTransaction npgsqlTransaction;
        private Publication publication;

        [SetUp]
        public void Setup()
        {
            this.OverideService = new Mock<IParameterOverrideService>();
            this.parameterValueSetService = new Mock<IParameterValueSetService>();
            this.overrideValueSetService = new Mock<IParameterOverrideValueSetService>();
            this.parameterService = new Mock<IParameterService>();
            this.securityContext = new Mock<ISecurityContext>();
            this.transactionManager = new Mock<ICdp4TransactionManager>();
            this.publicationSideEffect = new PublicationSideEffect
            {
                ParameterService = this.parameterService.Object,
                ParameterOverrideService = this.OverideService.Object,
                ParameterValueSetService = this.parameterValueSetService.Object,
                ParameterOverrideValueSetService = this.overrideValueSetService.Object,
                TransactionManager = this.transactionManager.Object
            };

            this.npgsqlTransaction = null;
            var valuearray = new ValueArray<string>(new[] {"-"});

            var option1 = new Option(Guid.NewGuid(), 1);
            var option2 = new Option(Guid.NewGuid(), 1);
            var orderedOption1 = new OrderedItem { V = option1 };
            var orderedOption2 = new OrderedItem { V = option2 };
            this.iteration = new Iteration(Guid.NewGuid(), 1);
            var actualFiniteState = new ActualFiniteState(Guid.NewGuid(), 1);
            var parameterValueSet1 = new ParameterValueSet(Guid.NewGuid(), 1)
            {
                ActualState = actualFiniteState.Iid,
                ActualOption = option1.Iid,
                Manual = valuearray,
                Computed = valuearray,
                Reference = valuearray
            };
            var parameterValueSet2 = new ParameterValueSet(Guid.NewGuid(), 1)
            {
                ActualState = actualFiniteState.Iid,
                ActualOption = option2.Iid,
                Manual = valuearray,
                Computed = valuearray,
                Reference = valuearray
            };
            var parameter = new Parameter(Guid.NewGuid(), 1)
            {
                IsOptionDependent = true,
                StateDependence = actualFiniteState.Iid
            };
            parameter.ValueSet.Add(parameterValueSet1.Iid);
            parameter.ValueSet.Add(parameterValueSet2.Iid);
            var actualFiniteStateList = new ActualFiniteStateList(Guid.NewGuid(), 1);
            actualFiniteStateList.ActualState.Add(actualFiniteState.Iid);
            var parameterOverride = new ParameterOverride(Guid.NewGuid(), 1) { Parameter = parameter.Iid };
            var overrideValueset1 = new ParameterOverrideValueSet(Guid.NewGuid(), 1)
            {
                ParameterValueSet = parameterValueSet1.Iid,
                Manual = valuearray,
                Computed = valuearray,
                Reference = valuearray
            };
            var overrideValueset2 = new ParameterOverrideValueSet(Guid.NewGuid(), 1)
            {
                ParameterValueSet = parameterValueSet2.Iid,
                Manual = valuearray,
                Computed = valuearray,
                Reference = valuearray
            };

            parameterOverride.ValueSet.Add(overrideValueset1.Iid);
            parameterOverride.ValueSet.Add(overrideValueset2.Iid);

            var publishedParametersAndOverridesIids = new List<Guid> { parameter.Iid, parameterOverride.Iid };
            this.publication = new Publication(Guid.NewGuid(), 1);
            this.publication.PublishedParameter.AddRange(publishedParametersAndOverridesIids);
            this.iteration.Publication.Add(this.publication.Iid);
            this.iteration.Option.Add(orderedOption1);
            this.iteration.Option.Add(orderedOption2);


            this.parameterService.Setup(x => x.GetShallow(It.IsAny<NpgsqlTransaction>(), It.IsAny<string>(), It.IsAny<IEnumerable<Guid>>(), this.securityContext.Object)).Returns(new [] { parameter });
            this.OverideService.Setup(x => x.GetShallow(It.IsAny<NpgsqlTransaction>(), It.IsAny<string>(), It.IsAny<IEnumerable<Guid>>(), this.securityContext.Object)).Returns(new [] { parameterOverride});
            this.parameterValueSetService.Setup(x => x.GetShallow(It.IsAny<NpgsqlTransaction>(), It.IsAny<string>(), It.IsAny<IEnumerable<Guid>>(), this.securityContext.Object)).Returns(new [] { parameterValueSet1, parameterValueSet2 });
            this.overrideValueSetService.Setup(x => x.GetShallow(It.IsAny<NpgsqlTransaction>(), It.IsAny<string>(), It.IsAny<IEnumerable<Guid>>(), this.securityContext.Object)).Returns(new [] { overrideValueset1 , overrideValueset2 });

            this.parameterValueSetService.Setup(x => x.UpdateConcept(It.IsAny<NpgsqlTransaction>(), It.IsAny<string>(), It.IsAny<ParameterValueSetBase>(), It.IsAny<ParameterOrOverrideBase>())).Returns(true);
            this.overrideValueSetService.Setup(x => x.UpdateConcept(It.IsAny<NpgsqlTransaction>(), It.IsAny<string>(), It.IsAny<ParameterValueSetBase>(), It.IsAny<ParameterOrOverrideBase>())).Returns(true);

            this.transactionManager.Setup(x => x.GetTransactionTime(It.IsAny<NpgsqlTransaction>())).Returns(DateTime.Now);
        }

        [Test]
        public void VerifyBeforeCreate()
        {
            this.publicationSideEffect.BeforeCreate(this.publication, this.iteration, this.npgsqlTransaction, "EngineeringModel", this.securityContext.Object);

            // Check that the value sets of the parameters and parameterOverrides included in this publications are updated
            this.parameterValueSetService.Verify(x => 
                x.UpdateConcept(this.npgsqlTransaction, "EngineeringModel", It.IsAny<ParameterValueSetBase>(), It.IsAny<ParameterOrOverrideBase>()), 
                Times.Exactly(2));

            this.overrideValueSetService.Verify(x =>
                    x.UpdateConcept(this.npgsqlTransaction, "EngineeringModel", It.IsAny<ParameterValueSetBase>(), It.IsAny<ParameterOrOverrideBase>()),
                Times.Exactly(2));
        }
    }
}
