﻿// --------------------------------------------------------------------------------------------------------------------
// <copyright file="ParameterSubscriptionSideEffectTestFixture.cs" company="RHEA System S.A.">
//   Copyright (c) 2017 RHEA System S.A.
// </copyright>
// --------------------------------------------------------------------------------------------------------------------

namespace CDP4WebServices.API.Tests.SideEffects
{
    using System;
    using System.Collections.Generic;
    using System.Linq;
    using CDP4Common;
    using CDP4Common.DTO;
    using CDP4Common.Exceptions;
    using CDP4Common.Types;
    using CDP4WebServices.API.Services;
    using CDP4WebServices.API.Services.Authorization;
    using CDP4WebServices.API.Services.Operations.SideEffects;
    using Moq;
    using Npgsql;
    using NUnit.Framework;

    /// <summary>
    /// Suite of tests for the <see cref="ParameterSubscriptionSideEffect"/>
    /// </summary>
    [TestFixture]
    public class ParameterSubscriptionSideEffectTestFixture
    {
        private Mock<ISecurityContext> securityContext;
        private Mock<IParameterSubscriptionValueSetService> parameterSubscriptionValueSetService;
        private Mock<IParameterValueSetService> parameterValueSetService;
        private Mock<IParameterOverrideValueSetService> parameterValueSetOverrideService;
        private Mock<IParameterSubscriptionService> parameterSubscriptionService;
        private Mock<IParameterService> parameterService;
        private Mock<IParameterOverrideService> parameterOverrideService;


        private NpgsqlTransaction npgsqlTransaction;
        private ParameterSubscriptionSideEffect sideEffect;

        [SetUp]
        public void Setup()
        {
            this.securityContext = new Mock<ISecurityContext>();
            this.npgsqlTransaction = null;
            this.parameterValueSetService = new Mock<IParameterValueSetService>();
            this.parameterValueSetOverrideService = new Mock<IParameterOverrideValueSetService>();
            this.parameterSubscriptionService = new Mock<IParameterSubscriptionService>();
            this.parameterService = new Mock<IParameterService>();
            this.parameterOverrideService = new Mock<IParameterOverrideService>();

            this.parameterSubscriptionValueSetService = new Mock<IParameterSubscriptionValueSetService>();
            this.parameterSubscriptionValueSetService.Setup(
                x => x.CreateConcept(
                    It.IsAny<NpgsqlTransaction>(),
                    It.IsAny<string>(),
                    It.IsAny<ParameterSubscriptionValueSet>(),
                    It.IsAny<ParameterSubscription>(),
                    It.IsAny<long>())).Returns(true);
            
            this.sideEffect = new ParameterSubscriptionSideEffect()
                                  {
                                      ParameterSubscriptionValueSetService = this.parameterSubscriptionValueSetService.Object,
                                      ParameterValueSetService = this.parameterValueSetService.Object,
                                      ParameterOverrideValueSetService = this.parameterValueSetOverrideService.Object,
                                      DefaultValueArrayFactory = new DefaultValueArrayFactory(),
                                      ParameterSubscriptionService = this.parameterSubscriptionService.Object,
                                      ParameterService = this.parameterService.Object,
                                      ParameterOverrideService = this.parameterOverrideService.Object
                                  };            
        }

        [Test]
        public void VerifyThatTheWhenOwnerOfTheParameterAndSubscriptionAreEqualExceptionIsThrown()
        {
            var owner = Guid.NewGuid();
            var parameterSubscription = new ParameterSubscription(Guid.NewGuid(), 1) {Owner = owner};
            
            var parameter = new Parameter(Guid.NewGuid(), 1) {Owner = owner};
            parameter.ValueSet.Add(Guid.NewGuid());
            parameter.ParameterSubscription.Add(parameterSubscription.Iid);

            this.parameterService
                .Setup(x => x.GetShallow(this.npgsqlTransaction, "partition", It.Is<IEnumerable<Guid>>(i => i.Single() == parameter.Iid), this.securityContext.Object))
                .Returns(new Thing[] { parameter });
            
            Assert.Throws<Cdp4ModelValidationException>(() => this.sideEffect.BeforeCreate(parameterSubscription, parameter, this.npgsqlTransaction, "partition", this.securityContext.Object));

            Assert.Throws<Cdp4ModelValidationException>(() => this.sideEffect.BeforeUpdate(parameterSubscription, parameter, this.npgsqlTransaction, "partition", this.securityContext.Object, null));
        }

        [Test]
        public void VerifyThatWhenAParameterSubscriptionIsPostedValueSetsAreCreated()
        {
            this.parameterValueSetService
                .Setup(x => x.GetShallow(It.IsAny<NpgsqlTransaction>(), "partition", It.IsAny<IEnumerable<Guid>>(), It.IsAny<ISecurityContext>()))
                .Returns(new [] { new ParameterValueSet(Guid.NewGuid(), 0) {Manual = new ValueArray<string>(new[] {"1", "2"})}});

            var parameterSubscription = new ParameterSubscription(Guid.NewGuid(), 1) { Owner = Guid.NewGuid() } ;
            var originalparameterSubscription = new ParameterSubscription(parameterSubscription.Iid, 1);

            var parameter = new Parameter(Guid.NewGuid(), 1) { Owner = Guid.NewGuid() } ;
            parameter.ValueSet = new List<Guid>() { Guid.NewGuid() };

            this.parameterService
                .Setup(x => x.GetShallow(It.IsAny<NpgsqlTransaction>(), "partition", It.Is<IEnumerable<Guid>>(enu => enu.Contains(parameter.Iid)), It.IsAny<ISecurityContext>()))
                .Returns(new[] { parameter });

            this.sideEffect.AfterCreate(parameterSubscription, parameter, originalparameterSubscription, this.npgsqlTransaction, "partition", this.securityContext.Object);
            
            this.parameterSubscriptionValueSetService.Verify(x => x.CreateConcept(this.npgsqlTransaction, "partition", It.Is<ParameterSubscriptionValueSet>(s => s.Manual.Count == 2), It.IsAny<ParameterSubscription>(), It.IsAny<long>()), Times.Once);
        }

        [Test]
        public void CheckThatMultipleSubscriptionCannotBeCreatedForSameOwner()
        {
            var subOwnerGuid = Guid.NewGuid();
            var existingSub = new ParameterSubscription(Guid.NewGuid(), 1) { Owner = subOwnerGuid };
            var parameterSubscription = new ParameterSubscription(Guid.NewGuid(), 1) { Owner = subOwnerGuid };

            var parameter = new Parameter(Guid.NewGuid(), 1) { Owner = Guid.NewGuid() };
            parameter.ValueSet = new List<Guid>() { Guid.NewGuid() };
            parameter.ParameterSubscription.Add(existingSub.Iid);

            this.parameterService
                .Setup(x => x.GetShallow(this.npgsqlTransaction, "partition", It.Is<IEnumerable<Guid>>(i => i.Single() == parameter.Iid), this.securityContext.Object))
                .Returns(new Thing[] { parameter });

            this.parameterSubscriptionService.Setup(x => x.GetShallow(this.npgsqlTransaction, "partition", It.Is<IEnumerable<Guid>>(y => y.Contains(existingSub.Iid)), this.securityContext.Object)).
                Returns(new List<Thing> {existingSub});

           Assert.IsFalse(this.sideEffect.BeforeCreate(parameterSubscription, parameter, this.npgsqlTransaction, "partition", this.securityContext.Object));
        }
    }
}
